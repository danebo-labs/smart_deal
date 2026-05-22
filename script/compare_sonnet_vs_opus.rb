# frozen_string_literal: true

# Usage: bin/rails runner script/compare_sonnet_vs_opus.rb [folder]
#
# Benchmark 3-eje para validar arquitectura de 3 paths (2026-05-21):
#   eje 1 (modelo):  {Haiku 4.5, Sonnet 4.6, Opus 4.7}
#   eje 2 (prompt):  {monolithic = BatchChunkingPrompt::SYSTEM_BLOCKS, specialized = por tipo}
#   eje 3 (input):   {foto, diagrama, manual}  — 3 inputs curados por tipo = 9 inputs
#
# Total LLM calls: 9 inputs * 3 modelos * 2 prompts = 54 extracciones
#                + 54 judge calls (Sonnet rubric independiente) = 108 calls (~$5)
#
# Capa el set anterior: forzaba test2.pdf y picking estratificado de imágenes con Haiku.
# El set nuevo se cura a mano y vive en subcarpetas: folder/foto/, folder/diagrama/, folder/manual/.
#
# Arregla los 3 sesgos del benchmark anterior:
#   1. Judge ve chunks/components/connections COMPLETOS (no truncado a 500 chars)
#   2. Retry on parse failure (1 reintento forzando JSON-only)
#   3. Scoring por criterio rubric INDEPENDIENTE por output (no comparación pareada → sin anchoring bias)
#
# Sin BD, sin S3, sin Solid Queue. Solo lectura de archivos + stdout.

require "concurrent"
require "stringio"
require "fileutils"

INPUT_TYPES = %w[foto diagrama manual].freeze

MODELS = {
  haiku:  PageRelevanceFilter::HAIKU_MODEL,           # claude-haiku-4-5-20251001
  sonnet: BatchChunkingPrompt::MODEL_TEXT,            # claude-sonnet-4-6
  opus:   BatchChunkingPrompt::MODEL_MULTIMODAL       # claude-opus-4-7
}.freeze

PROMPT_VARIANTS = %i[monolithic specialized].freeze

JUDGE_MODEL    = BatchChunkingPrompt::MODEL_TEXT      # Sonnet 4.6 — más capaz que Haiku, 5x más barato que Opus
MAX_TOKENS     = BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS
RETRY_TOKENS   = BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS
JUDGE_MAX_TOK  = 1024
PDF_MAX_PAGES  = 20

IMAGE_EXTS = %w[.jpg .jpeg .png .webp .gif].freeze
PDF_EXTS   = %w[.pdf].freeze

# ── Prompts especializados (eje 2 = "specialized") ─────────────────────────
# Cada uno modela uno de los 3 paths de la arquitectura nueva (2026-05-21):
#   foto     → query path (identificación + RAG retrieve, NO chunking)
#   diagrama → ingestion topológico (components + connections)
#   manual   → ingestion procedural (S0-S18 recortado)

SPEC_FOTO_BLOCKS = [
  {
    type: "text",
    text: <<~PROMPT.strip,
      ROLE: Senior Elevator Engineer parsing a FIELD PHOTO for technician RAG.
      This is the QUERY-TIME identification path — NO S0-S18 chunking, NO components/connections.

      Return ONLY a single valid JSON object — no markdown, no prose.
      Schema:
      {
        "canonical_component": "<3-5 word name of what is in the photo>",
        "manufacturer": "<brand explicitly visible or UNKNOWN>",
        "model": "<model/part code if visible or UNKNOWN>",
        "subsystem": "<SAFETY_CHAIN|BRAKE_SYSTEM|DOOR_OPERATOR|MOTOR_DRIVE|GOVERNOR_SYSTEM|CONTROLLER_LOGIC|POWER_SUPPLY|SIGNALING_SYSTEM|EMERGENCY_SYSTEM|PIT_EQUIPMENT|CAR_TOP_EQUIPMENT|UNKNOWN>",
        "condition": "<GOOD|DEGRADED|DAMAGED|UNKNOWN>",
        "aliases": ["<alias 1>", "<alias 2>", ...],
        "summary": "<warm 2-3 sentences in the requested locale, no jargon, no specs>",
        "anti_hallucination_notes": "<1 sentence: what was inferred vs explicitly visible>"
      }

      RULES:
      - NEVER assume manufacturer from visual patterns (R0-R13 anti-hallucination).
      - Aliases ONLY from visible labels / printed text.
      - Default to UNKNOWN when not explicit.
      - No fabricated specs (voltages, dimensions, torques) anywhere.
      - Summary: warm trusted-colleague voice, 2-3 sentences, plain language.
    PROMPT
    cache_control: { type: "ephemeral" }
  }
].freeze

SPEC_DIAGRAMA_BLOCKS = [
  {
    type: "text",
    text: <<~PROMPT.strip,
      ROLE: Senior Elevator Engineer parsing a SCHEMATIC / DIAGRAM for RAG ingestion.
      This is the TOPOLOGICAL ingestion path — emit components[] + connections[], NOT S0-S18 chunks.

      Return ONLY a single valid JSON object — no markdown, no prose.
      Schema:
      {
        "document_name": "<3-7 word title>",
        "aliases": ["<alias 1>", "<alias 2>", ...],
        "components": [
          { "id": "<as labeled, e.g. X1, K2, M1>",
            "label": "<verbatim text on the diagram>",
            "type": "<terminal|relay|contactor|sensor|motor|drive|breaker|switch|fuse|transformer|other>" }
        ],
        "connections": [
          { "from": "<component id or label>",
            "to":   "<component id or label>",
            "via":  "<wire ref / cable / circuit number, if visible — else null>" }
        ],
        "summary": "<warm 2-3 sentences in requested locale>",
        "anti_hallucination_notes": "<1 sentence: what was inferred vs visible>"
      }

      RULES:
      - Components MUST come from visible labels.
      - Connections only when BOTH endpoints are visible — otherwise OMIT (do NOT guess).
      - No S0-S18 chunks.
      - R0-R13 anti-hallucination apply.
    PROMPT
    cache_control: { type: "ephemeral" }
  }
].freeze

SPEC_MANUAL_BLOCKS = [
  {
    type: "text",
    text: <<~PROMPT.strip,
      ROLE: Senior Elevator Engineer parsing a MANUAL PAGE for RAG ingestion (procedural path).
      Emit S0-S18 chunks (trimmed of foto/diagrama-specific guidance — assume input is procedural text/tables).

      Return ONLY a single valid JSON object — no markdown, no prose.
      Schema:
      {
        "document_name": "<3-7 words>",
        "aliases": ["<alias>", ...],
        "summary": "<warm 2-3 sentences in requested locale, no jargon>",
        "companion_offer": "<1 warm invitation in requested locale>",
        "chunks": [
          { "text": "<chunk body — section header inside the body>", "page": <integer or null> }
        ]
      }

      Sections (emit ONLY those genuinely present in the page):
        S0  — DOCUMENT IDENTIFICATION (mandatory chunk[0]; small identification table)
        S4  — SAFETY SYSTEM
        S6  — ELECTRICAL
        S7  — DIAGRAM
        S10 — TROUBLESHOOTING
        S16 — INSTALLATION
        S17 — MODERNIZATION
        S18 — COMMISSIONING

      RULES:
      - Preserve verbatim numeric values, codes, terminal labels.
      - chunk[0] MUST be S0 with the standard identification table.
      - ORIGINAL_FILE_NAME / NORMALIZED_FILE_NAME / SOURCE_URI = PIPELINE_INJECTED.
      - R0-R13 anti-hallucination apply (no fabricated voltages/torques/etc).
      - Target ~150-700 words per chunk; never exceed ~1000.
    PROMPT
    cache_control: { type: "ephemeral" }
  }
].freeze

SPECIALIZED_BLOCKS = {
  "foto"     => SPEC_FOTO_BLOCKS,
  "diagrama" => SPEC_DIAGRAMA_BLOCKS,
  "manual"   => SPEC_MANUAL_BLOCKS
}.freeze

# ── Judge prompts (rubric INDEPENDIENTE — bias-fix #3) ─────────────────────
# Cada output se evalúa SOLO (no side-by-side) contra una rúbrica 0-5 por criterio.
# Eso evita anchoring bias del judge anterior que recibía pareados a/b.

JUDGE_FOTO_SYSTEM = <<~PROMPT.strip.freeze
  You score ONE elevator field-photo identification output for technician RAG.
  Return ONLY a single valid JSON object — no markdown, no prose.
  Score each criterion 0-5 (5 = excellent, 0 = unusable).

  Schema:
  {
    "identification":       {"score": 0-5, "reason": "<15 words>"},
    "content_faithfulness": {"score": 0-5, "reason": "<15 words>"},
    "summary":              {"score": 0-5, "reason": "<15 words>"},
    "anti_hallucination":   {"score": 0-5, "reason": "<15 words>"}
  }

  Rubric:
  - identification: how accurate are canonical_component / manufacturer / model / subsystem against visible content?
  - content_faithfulness: do aliases + condition match what is in the image (no fabrication)?
  - summary: warm, 2-3 sentences, no jargon, technician-friendly?
  - anti_hallucination: are inferred fields properly marked UNKNOWN? are notes accurate?
PROMPT

JUDGE_DIAGRAMA_SYSTEM = <<~PROMPT.strip.freeze
  You score ONE elevator schematic / diagram extraction output (topological ingestion).
  Return ONLY a single valid JSON object — no markdown.
  Score each criterion 0-5.

  Schema:
  {
    "identification":       {"score": 0-5, "reason": "<15 words>"},
    "content_faithfulness": {"score": 0-5, "reason": "<15 words>"},
    "summary":              {"score": 0-5, "reason": "<15 words>"},
    "anti_hallucination":   {"score": 0-5, "reason": "<15 words>"}
  }

  Rubric:
  - identification: document_name + aliases derived faithfully from the visible diagram?
  - content_faithfulness: components[] + connections[] match visible labels and topology? endpoints real?
  - summary: 2-3 plain sentences for a field technician?
  - anti_hallucination: speculative connections omitted? no fabricated components/labels?
PROMPT

JUDGE_MANUAL_SYSTEM = <<~PROMPT.strip.freeze
  You score ONE elevator manual page extraction output (procedural ingestion, S0-S18 chunks).
  Return ONLY a single valid JSON object — no markdown.
  Score each criterion 0-5.

  Schema:
  {
    "identification":       {"score": 0-5, "reason": "<15 words>"},
    "content_faithfulness": {"score": 0-5, "reason": "<15 words>"},
    "summary":              {"score": 0-5, "reason": "<15 words>"},
    "anti_hallucination":   {"score": 0-5, "reason": "<15 words>"}
  }

  Rubric:
  - identification: document_name + aliases match the manual content?
  - content_faithfulness: chunks preserve verbatim values/codes/terminal labels? sections labeled correctly (S0-S18)? chunk[0] = S0?
  - summary: warm 2-3 sentences for a field technician?
  - anti_hallucination: numbers/voltages/torques NOT fabricated? UNKNOWN / DATA_NOT_AVAILABLE used appropriately?
PROMPT

JUDGE_SYSTEM_BY_TYPE = {
  "foto"     => JUDGE_FOTO_SYSTEM,
  "diagrama" => JUDGE_DIAGRAMA_SYSTEM,
  "manual"   => JUDGE_MANUAL_SYSTEM
}.freeze

CRITERIA = %i[identification content_faithfulness summary anti_hallucination].freeze

# ── Helpers ────────────────────────────────────────────────────────────────

def folder_arg
  ARGV[0].presence || File.expand_path("~/Desktop/benchmark")
end

def expected_total_inputs
  INPUT_TYPES.size * 3 # 3 foto + 3 diagrama + 3 manual = 9
end

def expected_extraction_calls
  expected_total_inputs * MODELS.size * PROMPT_VARIANTS.size # 9 * 3 * 2 = 54
end

def collect_inputs(folder)
  inputs = []
  INPUT_TYPES.each do |type|
    sub = File.join(folder, type)
    unless Dir.exist?(sub)
      warn "WARN: subdir missing: #{sub} — skipping #{type}"
      next
    end
    files = Dir.children(sub).sort.filter_map do |name|
      path = File.join(sub, name)
      next unless File.file?(path)

      ext = File.extname(name).downcase
      next unless (IMAGE_EXTS + PDF_EXTS).include?(ext)

      { type: type, path: path }
    end
    if files.empty?
      warn "WARN: no usable files in #{sub}"
    else
      inputs.concat(files)
      flag = files.size == 3 ? "" : "  [expected 3, got #{files.size}]"
      puts "  #{type}: #{files.size} file(s)#{flag} — #{files.map { |f| File.basename(f[:path]) }.inspect}"
    end
  end
  inputs
end

def content_type_for(path)
  case File.extname(path).downcase
  when ".jpg", ".jpeg" then "image/jpeg"
  when ".png"          then "image/png"
  when ".webp"         then "image/webp"
  when ".gif"          then "image/gif"
  when ".pdf"          then "application/pdf"
  else                       "application/octet-stream"
  end
end

def read_binary(path)
  binary = File.binread(path)
  return binary unless File.extname(path).downcase == ".pdf"

  splitter = PdfPageSplitterService.new(binary)
  count    = splitter.page_count
  return binary if count <= PDF_MAX_PAGES

  warn "WARN: #{File.basename(path)} tiene #{count} paginas — truncando a #{PDF_MAX_PAGES}"
  pages = []
  splitter.each_page { |num, page_bin| pages << page_bin if num <= PDF_MAX_PAGES }
  combine_pdf_pages(pages)
end

def combine_pdf_pages(page_binaries)
  doc = HexaPDF::Document.new
  page_binaries.each do |page_bin|
    source = HexaPDF::Document.new(io: StringIO.new(page_bin))
    doc.pages << doc.import(source.pages.first)
  end
  io = StringIO.new("".b)
  doc.write(io, validate: false)
  io.string
end

def system_blocks_for(prompt_variant, type)
  case prompt_variant
  when :monolithic  then BatchChunkingPrompt::SYSTEM_BLOCKS
  when :specialized then SPECIALIZED_BLOCKS.fetch(type)
  else raise ArgumentError, "unknown prompt variant: #{prompt_variant}"
  end
end

def parse_json_loose(text)
  cleaned = text.to_s.strip.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "")
  JSON.parse(cleaned)
end

# Bias-fix #2: 1 retry on parse failure forcing JSON-only correction.
# Captura tokens/lat del retry sumando al primer call (transparencia de costo).
def call_extractor(client, model:, system:, user_content:)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  msg = client.messages.stream(
    model:      model,
    max_tokens: MAX_TOKENS,
    system:     system,
    messages:   [ { role: "user", content: user_content } ]
  ).accumulated_message
  ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

  text   = msg.content.find { |b| b.type.to_s == "text" }&.text.to_s
  parsed = (parse_json_loose(text) rescue nil)

  retry_meta = nil
  if parsed.nil?
    retry_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    msg2 = client.messages.stream(
      model:      model,
      max_tokens: RETRY_TOKENS,
      system:     system,
      messages: [
        { role: "user",      content: user_content },
        { role: "assistant", content: text },
        { role: "user",      content: "Your previous output was not valid JSON. Re-emit the SAME data as ONLY a single valid JSON object — no markdown, no commentary, no code fences." }
      ]
    ).accumulated_message
    text2 = msg2.content.find { |b| b.type.to_s == "text" }&.text.to_s
    parsed_retry = (parse_json_loose(text2) rescue nil)
    retry_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - retry_start) * 1000).round
    retry_meta = {
      input:   msg2.usage.input_tokens.to_i,
      output:  msg2.usage.output_tokens.to_i,
      cache_c: (msg2.usage.respond_to?(:cache_creation_input_tokens) ? msg2.usage.cache_creation_input_tokens.to_i : 0),
      cache_r: (msg2.usage.respond_to?(:cache_read_input_tokens)     ? msg2.usage.cache_read_input_tokens.to_i     : 0),
      ms:      retry_ms,
      stop:    (msg2.respond_to?(:stop_reason) ? msg2.stop_reason.to_s : nil),
      raw:     text2
    }
    if parsed_retry
      parsed = parsed_retry
      text   = text2
    end
  end

  parsed ||= { "_parse_failed" => true, "aliases" => [], "chunks" => [], "components" => [], "connections" => [] }

  base_cache_c = (msg.usage.respond_to?(:cache_creation_input_tokens) ? msg.usage.cache_creation_input_tokens.to_i : 0)
  base_cache_r = (msg.usage.respond_to?(:cache_read_input_tokens)     ? msg.usage.cache_read_input_tokens.to_i     : 0)

  {
    model:        model,
    input:        msg.usage.input_tokens.to_i  + retry_meta&.dig(:input).to_i,
    output:       msg.usage.output_tokens.to_i + retry_meta&.dig(:output).to_i,
    cache_c:      base_cache_c + retry_meta&.dig(:cache_c).to_i,
    cache_r:      base_cache_r + retry_meta&.dig(:cache_r).to_i,
    parsed:       parsed,
    raw_text:     text,
    stop_reason:  retry_meta ? retry_meta[:stop] : (msg.respond_to?(:stop_reason) ? msg.stop_reason.to_s : nil),
    latency_ms:   ms + retry_meta&.dig(:ms).to_i,
    parse_failed: parsed["_parse_failed"] == true,
    retried:      !retry_meta.nil?
  }
rescue StandardError => e
  warn "WARN: extractor failed (#{model}): #{e.class} #{e.message}"
  {
    model: model, input: 0, output: 0, cache_c: 0, cache_r: 0,
    parsed: { "_call_failed" => true, "error" => e.message, "aliases" => [], "chunks" => [], "components" => [], "connections" => [] },
    raw_text: "", stop_reason: "error", latency_ms: 0,
    parse_failed: true, retried: false, call_failed: true
  }
end

def pricing_for(model)
  key = model.end_with?("-direct") ? model : "#{model}-direct"
  BedrockQuery::BEDROCK_PRICING.fetch(key)
end

def cost_for(input:, output:, cache_c:, cache_r:, model:)
  p = pricing_for(model)
  (input   * p[:input]                                +
   output  * p[:output]                               +
   cache_c * (p[:cache_creation] || p[:input] * 1.25) +
   cache_r * (p[:cache_read]     || p[:input] * 0.1)) / 1000.0
end

# ── Judge (rubric INDEPENDIENTE — bias-fix #3) ─────────────────────────────
# Cada output se manda solo al judge con su rúbrica de tipo. Sin pares, sin anchoring.
# Bias-fix #1: chunks/components/connections COMPLETOS (sin truncar a 500 chars).

def judge_payload(parsed, type)
  case type
  when "foto"
    parsed.slice("canonical_component", "manufacturer", "model", "subsystem",
                 "condition", "aliases", "summary", "anti_hallucination_notes",
                 "document_name") # document_name aparece si lo emitió el monolítico
  when "diagrama"
    parsed.slice("document_name", "aliases", "components", "connections",
                 "summary", "anti_hallucination_notes")
  when "manual"
    {
      "document_name"   => parsed["document_name"],
      "aliases"         => parsed["aliases"],
      "summary"         => parsed["summary"],
      "companion_offer" => parsed["companion_offer"],
      "chunks"          => (parsed["chunks"] || []).map { |c| { "text" => c["text"].to_s, "page" => c["page"] } }
    }
  end
end

def judge_scores_empty?(scores)
  return true if scores.nil? || !scores.is_a?(Hash) || scores.empty?
  CRITERIA.all? { |c| scores.dig(c.to_s, "score").nil? }
end

def call_judge(client, type:, parsed:, source_meta:)
  payload = judge_payload(parsed, type)
  base_user = "INPUT_TYPE: #{type}\nSOURCE_FILE: #{source_meta[:filename]}\n\nOUTPUT_TO_SCORE:\n#{JSON.pretty_generate(payload)}"
  base_system = JUDGE_SYSTEM_BY_TYPE.fetch(type)

  msg = client.messages.stream(
    model:      JUDGE_MODEL,
    max_tokens: JUDGE_MAX_TOK,
    system:     base_system,
    messages:   [ { role: "user", content: [ { type: "text", text: base_user } ] } ]
  ).accumulated_message
  text   = msg.content.find { |b| b.type.to_s == "text" }&.text.to_s
  scores = (parse_json_loose(text) rescue {})
  in_tok  = msg.usage.input_tokens.to_i
  out_tok = msg.usage.output_tokens.to_i
  retried = false

  if judge_scores_empty?(scores)
    retried = true
    msg2 = client.messages.stream(
      model:      JUDGE_MODEL,
      max_tokens: JUDGE_MAX_TOK * 2,
      system:     base_system + "\n\nIMPORTANT: every criterion MUST have an integer score 0-5 AND a non-empty reason. Output JSON only.",
      messages: [
        { role: "user",      content: [ { type: "text", text: base_user } ] },
        { role: "assistant", content: text.to_s.empty? ? "{}" : text },
        { role: "user",      content: [ { type: "text", text: "Your previous response was empty or had no scores. Re-emit ONLY a single JSON object with all 4 criteria scored 0-5 and a non-empty reason for each. No markdown, no commentary." } ]
        }
      ]
    ).accumulated_message
    text2 = msg2.content.find { |b| b.type.to_s == "text" }&.text.to_s
    scores2 = (parse_json_loose(text2) rescue {})
    in_tok  += msg2.usage.input_tokens.to_i
    out_tok += msg2.usage.output_tokens.to_i
    scores = scores2 unless judge_scores_empty?(scores2)
  end

  judge_failed = judge_scores_empty?(scores)
  scores ||= {}

  {
    identification:       scores.dig("identification",       "score").to_i,
    content_faithfulness: scores.dig("content_faithfulness", "score").to_i,
    summary:              scores.dig("summary",              "score").to_i,
    anti_hallucination:   scores.dig("anti_hallucination",   "score").to_i,
    reasons: {
      identification:       scores.dig("identification",       "reason").to_s,
      content_faithfulness: scores.dig("content_faithfulness", "reason").to_s,
      summary:              scores.dig("summary",              "reason").to_s,
      anti_hallucination:   scores.dig("anti_hallucination",   "reason").to_s
    },
    judge_input:    in_tok,
    judge_output:   out_tok,
    judge_retried:  retried,
    judge_failed:   judge_failed,
    raw: scores
  }
rescue StandardError => e
  warn "WARN: judge failed: #{e.class} #{e.message}"
  { identification: 0, content_faithfulness: 0, summary: 0, anti_hallucination: 0,
    reasons: {}, judge_input: 0, judge_output: 0,
    judge_retried: false, judge_failed: true, raw: {} }
end

def avg(arr)
  return 0.0 if arr.empty?
  arr.sum.to_f / arr.size
end

def fmt2(v) format("%.2f", v) end

# ── Main ───────────────────────────────────────────────────────────────────

folder = folder_arg
abort "ERROR: folder no existe: #{folder}\nLayout esperado: #{folder}/foto/  #{folder}/diagrama/  #{folder}/manual/" unless Dir.exist?(folder)

api_key = ENV.fetch("ANTHROPIC_API_KEY", nil).presence ||
          Rails.application.credentials.dig(:anthropic, :api_key)
abort "ERROR: ANTHROPIC_API_KEY no encontrado (env ni credentials.dig(:anthropic, :api_key))" if api_key.to_s.empty?

client = Anthropic::Client.new(api_key: api_key)

only_files = ENV["ONLY_FILES"].to_s.split(",").map(&:strip).reject(&:empty?).to_set
only_cells = ENV["ONLY_CELLS"].to_s.split(",").map(&:strip).reject(&:empty?).to_set

run_id     = Time.zone.now.strftime("%Y%m%d_%H%M%S")
suffix     = (only_files.any? || only_cells.any?) ? "_partial" : ""
dump_path  = Rails.root.join("tmp", "benchmark_3axes_#{run_id}#{suffix}.json").to_s
FileUtils.mkdir_p(File.dirname(dump_path))

puts "=== Benchmark 3-eje: {Haiku, Sonnet, Opus} × {monolithic, specialized} × {foto, diagrama, manual} ==="
puts "Folder:    #{folder}"
puts "Judge:     #{JUDGE_MODEL}  (rubric independiente, 0-5 por criterio, 4 criterios)"
puts "Bias fixes: 1) outputs completos al judge  2) retry parse extractor  3) rubric per-output  4) retry judge on empty"
puts "Dump:      #{dump_path}"
if only_files.any? || only_cells.any?
  puts "Filters:   ONLY_FILES=#{only_files.to_a.inspect}  ONLY_CELLS=#{only_cells.to_a.inspect}  (run parcial)"
else
  puts "Budget:    ~$5 estimado (#{expected_extraction_calls} extraction + #{expected_extraction_calls} judge calls)"
end
puts

inputs = collect_inputs(folder)
abort "ERROR: 0 inputs encontrados — esperaba archivos en #{folder}/{foto,diagrama,manual}/" if inputs.empty?

if inputs.size != expected_total_inputs
  warn "WARN: total inputs = #{inputs.size}, esperado #{expected_total_inputs} (3 por tipo). Sigo igual, pero las agregaciones quedan desbalanceadas."
end
puts "Total inputs: #{inputs.size}  (esperado #{expected_total_inputs}: 3 foto + 3 diagrama + 3 manual)"
puts

results = []  # flat list of (input × model × prompt) records

inputs.each do |entry|
  type     = entry[:type]
  path     = entry[:path]
  filename = File.basename(path)

  if only_files.any? && only_files.exclude?(filename)
    next
  end

  combos = MODELS.flat_map do |mkey, model|
    PROMPT_VARIANTS.map { |pv| { mkey: mkey, model: model, pv: pv } }
  end
  if only_cells.any?
    combos = combos.select { |c| only_cells.include?("#{c[:mkey]}:#{c[:pv]}") }
    next if combos.empty?
  end

  binary = read_binary(path)
  ct     = content_type_for(path)
  user_content = BatchChunkingPrompt.user_content(
    binary: binary, content_type: ct, filename: filename, locale: "es"
  )

  puts "=== [#{type}] #{filename} ==="

  futures = combos.map do |c|
    Concurrent::Promises.future do
      sys = system_blocks_for(c[:pv], type)
      call_extractor(client, model: c[:model], system: sys, user_content: user_content)
        .merge(type: type, mkey: c[:mkey], pv: c[:pv], filename: filename)
    end
  end
  outputs = Concurrent::Promises.zip(*futures).value!

  judge_futures = outputs.map do |o|
    Concurrent::Promises.future do
      call_judge(client, type: type, parsed: o[:parsed], source_meta: { filename: filename })
    end
  end
  judges = Concurrent::Promises.zip(*judge_futures).value!

  outputs.zip(judges).each do |o, j|
    extr_cost  = cost_for(input: o[:input], output: o[:output], cache_c: o[:cache_c], cache_r: o[:cache_r], model: o[:model])
    judge_cost = cost_for(input: j[:judge_input], output: j[:judge_output], cache_c: 0, cache_r: 0, model: JUDGE_MODEL)

    record = {
      type: type, filename: filename, mkey: o[:mkey], pv: o[:pv], model: o[:model],
      input: o[:input], output: o[:output], cache_c: o[:cache_c], cache_r: o[:cache_r],
      cost: extr_cost, judge_cost: judge_cost, latency_ms: o[:latency_ms],
      stop_reason: o[:stop_reason], parse_failed: o[:parse_failed], retried: o[:retried],
      aliases_n:    (o[:parsed]["aliases"]     || []).size,
      chunks_n:     (o[:parsed]["chunks"]      || []).size,
      components_n: (o[:parsed]["components"]  || []).size,
      connections_n: (o[:parsed]["connections"] || []).size,
      scores: CRITERIA.index_with { |c| j[c] },
      total_score: CRITERIA.sum { |c| j[c] },
      reasons: j[:reasons],
      judge_retried: j[:judge_retried],
      judge_failed:  j[:judge_failed],
      parsed:        o[:parsed],
      judge_payload: judge_payload(o[:parsed], type)
    }
    results << record

    flags = []
    flags << "retry"        if record[:retried]
    flags << "PARSE_FAILED" if record[:parse_failed]
    flags << "max_tokens"   if record[:stop_reason] == "max_tokens"
    flags << "JUDGE_RETRY"  if record[:judge_retried]
    flags << "JUDGE_FAILED" if record[:judge_failed]

    printf "  %-7s %-12s in:%5d out:%5d lat:%3ds $%.4f | scores id=%d cf=%d sum=%d ah=%d (Σ=%2d/20)%s\n",
      o[:mkey], o[:pv], o[:input], o[:output], (o[:latency_ms] / 1000.0).round, extr_cost,
      j[:identification], j[:content_faithfulness], j[:summary], j[:anti_hallucination],
      record[:total_score],
      flags.empty? ? "" : "  [#{flags.join(',')}]"
  end
  puts
end

# ── Aggregations ───────────────────────────────────────────────────────────

puts "=== AGGREGATES ==="
puts

judge_failed_rows = results.select { |r| r[:judge_failed] }
if judge_failed_rows.any?
  puts "Judge fails: #{judge_failed_rows.size} (excluidos del agregado)"
  judge_failed_rows.each { |r| puts "  - #{r[:filename]} | #{r[:mkey]} #{r[:pv]}" }
  puts
end
clean = results.reject { |r| r[:judge_failed] }

puts "By model (avg total / 20, avg cost, avg lat, parse_fail count):"
MODELS.each do |mkey, _|
  rs = clean.select { |r| r[:mkey] == mkey }
  next if rs.empty?
  printf "  %-7s  Σ=%5s/20  $/call=%.4f  lat=%4.1fs  parse_fail=%d/%d  retry=%d  judge_retry=%d\n",
    mkey,
    fmt2(avg(rs.map { |r| r[:total_score] })),
    avg(rs.map { |r| r[:cost] }),
    avg(rs.map { |r| r[:latency_ms] / 1000.0 }),
    rs.count { |r| r[:parse_failed] }, rs.size,
    rs.count { |r| r[:retried] },
    rs.count { |r| r[:judge_retried] }
end
puts

puts "By prompt variant (avg total / 20):"
PROMPT_VARIANTS.each do |pv|
  rs = clean.select { |r| r[:pv] == pv }
  next if rs.empty?
  printf "  %-12s Σ=%5s/20  parse_fail=%d/%d\n",
    pv, fmt2(avg(rs.map { |r| r[:total_score] })),
    rs.count { |r| r[:parse_failed] }, rs.size
end
puts

puts "By input type (avg total / 20):"
INPUT_TYPES.each do |t|
  rs = clean.select { |r| r[:type] == t }
  next if rs.empty?
  printf "  %-9s Σ=%5s/20  parse_fail=%d/%d\n",
    t, fmt2(avg(rs.map { |r| r[:total_score] })),
    rs.count { |r| r[:parse_failed] }, rs.size
end
puts

puts "Interaction (model × prompt) per input type — avg Σ/20:"
INPUT_TYPES.each do |t|
  rs_t = clean.select { |r| r[:type] == t }
  next if rs_t.empty?
  puts "  [#{t}]"
  printf "    %-7s | %-13s | %-13s\n", "model", "monolithic", "specialized"
  MODELS.each do |mkey, _|
    mono = rs_t.select { |r| r[:mkey] == mkey && r[:pv] == :monolithic }
    spec = rs_t.select { |r| r[:mkey] == mkey && r[:pv] == :specialized }
    printf "    %-7s | %-13s | %-13s\n",
      mkey,
      mono.empty? ? "n/a" : "Σ=#{fmt2(avg(mono.map { |r| r[:total_score] }))}",
      spec.empty? ? "n/a" : "Σ=#{fmt2(avg(spec.map { |r| r[:total_score] }))}"
  end
end
puts

puts "Per-criterion avg score by model (collapsing prompt × type):"
header = MODELS.keys.map { |k| format("%7s", k) }.join(" | ")
printf "  %-22s | %s\n", "criterion", header
CRITERIA.each do |c|
  cells = MODELS.keys.map do |mkey|
    rs = clean.select { |r| r[:mkey] == mkey }
    format("%7s", fmt2(avg(rs.map { |r| r[:scores][c] })))
  end
  printf "  %-22s | %s\n", c, cells.join(" | ")
end
puts

puts "Per-criterion avg by model × type (foto / diagrama / manual):"
INPUT_TYPES.each do |t|
  puts "  [#{t}]"
  printf "    %-22s | %s\n", "criterion", header
  CRITERIA.each do |c|
    cells = MODELS.keys.map do |mkey|
      rs = clean.select { |r| r[:mkey] == mkey && r[:type] == t }
      format("%7s", rs.empty? ? "-" : fmt2(avg(rs.map { |r| r[:scores][c] })))
    end
    printf "    %-22s | %s\n", c, cells.join(" | ")
  end
end
puts

total_extr_cost  = results.sum { |r| r[:cost] }
total_judge_cost = results.sum { |r| r[:judge_cost] }
puts "Total cost:"
printf "  Extraction (%d calls): $%.4f\n", results.size, total_extr_cost
printf "  Judge      (%d calls): $%.4f\n", results.size, total_judge_cost
printf "  Total                : $%.4f  (budget esperado ~$5)\n", total_extr_cost + total_judge_cost
puts

# ── Decisión heurística ────────────────────────────────────────────────────

sonnet_avg = avg(clean.select { |r| r[:mkey] == :sonnet }.pluck(:total_score))
opus_avg   = avg(clean.select { |r| r[:mkey] == :opus   }.pluck(:total_score))
haiku_avg  = avg(clean.select { |r| r[:mkey] == :haiku  }.pluck(:total_score))

mono_avg   = avg(clean.select { |r| r[:pv] == :monolithic  }.pluck(:total_score))
spec_avg   = avg(clean.select { |r| r[:pv] == :specialized }.pluck(:total_score))

haiku_foto_avg  = avg(clean.select { |r| r[:mkey] == :haiku  && r[:type] == "foto" }.pluck(:total_score))
sonnet_foto_avg = avg(clean.select { |r| r[:mkey] == :sonnet && r[:type] == "foto" }.pluck(:total_score))

puts "VEREDICTO:"
printf "  Modelo:  Sonnet=%.2f  Opus=%.2f  Haiku=%.2f  (Σ promedio /20)\n", sonnet_avg, opus_avg, haiku_avg
printf "  Prompt:  monolithic=%.2f  specialized=%.2f\n", mono_avg, spec_avg
printf "  Foto:    Haiku=%.2f  Sonnet=%.2f  (¿basta Haiku para path identificación?)\n", haiku_foto_avg, sonnet_foto_avg
puts

if sonnet_avg + 0.5 >= opus_avg
  puts "  ✓ Sonnet 4.6 ≈ Opus 4.7 → migrar default a Sonnet (mantener Opus solo como force_opus para escaneados densos)."
else
  printf "  ✗ Opus claramente mejor (+%.2f /20) — mantener Opus por defecto.\n", (opus_avg - sonnet_avg)
end

if spec_avg >= mono_avg + 0.5
  printf "  ✓ Prompt especializado mejor que monolítico (+%.2f /20) → migrar a 3 prompts por path.\n", (spec_avg - mono_avg)
elsif mono_avg >= spec_avg + 0.5
  printf "  ✗ Monolítico mejor que especializado (+%.2f /20) — re-revisar prompts especializados.\n", (mono_avg - spec_avg)
else
  printf "  ~ Empate prompt monolithic vs specialized (Δ=%.2f /20) — costo o latencia decide.\n", (mono_avg - spec_avg).abs
end

if haiku_foto_avg + 1.0 >= sonnet_foto_avg
  printf "  ✓ Haiku basta para foto identificación (Δ=%.2f /20) — migrar path 1 a Haiku (aún más barato).\n", (sonnet_foto_avg - haiku_foto_avg)
else
  printf "  ✗ Haiku no alcanza para foto (-%.2f /20 vs Sonnet) — usar Sonnet en path identificación.\n", (sonnet_foto_avg - haiku_foto_avg)
end

# ── Dump JSON crudo (para análisis post-hoc — no quemar otros $5 si hay dudas) ─

File.write(dump_path, JSON.pretty_generate({
  run_id:    run_id,
  folder:    folder,
  models:    MODELS.transform_values(&:to_s),
  prompts:   PROMPT_VARIANTS,
  criteria:  CRITERIA,
  judge:     JUDGE_MODEL,
  total_extraction_cost: total_extr_cost,
  total_judge_cost:      total_judge_cost,
  results:   results.map { |r| r.merge(scores: r[:scores], reasons: r[:reasons]) }
}))
puts "Resultados crudos en: #{dump_path}"
