# frozen_string_literal: true

# Live F1 calibration runner. Retrieve is stubbed with the frozen fixture.
# One configured Haiku generation per case. Scoring is FieldCompanion::F1CalibrationScore.
#
#   DOCUMENT_IDENTITY_SCOPE_ENABLED=true BEDROCK_RERANKER_ENABLED=false \
#     bin/rails runner script/field_companion/f1_calibration_runner.rb
#
# F1CAL_VERSION, F1CAL_OUT, F1CAL_IDS, F1CAL_LANES, F1CAL_UNKNOWN_ONLY,
# F1CAL_SPEND_CAP (default 1.0 for this invocation's new spend),
# F1CAL_LEDGER (default tmp/f1cal/aprime_ledger.json).
# F1CAL_GROK=1 with BEDROCK_MODEL_ID=global.xai.grok-4.7 installs the
# benchmark Converse adapter. F1CAL_SONNET=1 with
# BEDROCK_MODEL_ID=global.anthropic.claude-sonnet-5-5 installs the Sonnet
# invoke adapter. F1CAL_SONNET_DIRECT=1 keeps the Haiku query model and sends
# only the composed generation call to the direct Anthropic API.
# A block-file override is refused.

STDOUT.sync = true

require_relative "f1_calibration_score"

Corpus = FieldCompanion::F1CalibrationCorpus
Score = FieldCompanion::F1CalibrationScore

abort "refusing F1CAL_BLOCK_FILE: the applicability block is frozen" if ENV["F1CAL_BLOCK_FILE"].present?

grok_requested = ENV["F1CAL_GROK"] == "1"
sonnet_requested = ENV["F1CAL_SONNET"] == "1"
sonnet_direct_requested = ENV["F1CAL_SONNET_DIRECT"] == "1"
abort "set only one benchmark model flag" if [ grok_requested, sonnet_requested, sonnet_direct_requested ].count(true) > 1
model_id = BedrockClient::QUERY_MODEL_ID.to_s
if grok_requested
  require_relative "f1_grok_generation"
  abort "BEDROCK_MODEL_ID must be #{FieldCompanion::F1GrokGeneration::MODEL_ID}" unless model_id == FieldCompanion::F1GrokGeneration::MODEL_ID
  FieldCompanion::F1GrokGeneration.install!
elsif sonnet_requested
  require_relative "f1_sonnet_generation"
  abort "BEDROCK_MODEL_ID must be #{FieldCompanion::F1SonnetGeneration::MODEL_ID}" unless model_id == FieldCompanion::F1SonnetGeneration::MODEL_ID
  FieldCompanion::F1SonnetGeneration.install!
elsif sonnet_direct_requested
  require_relative "f1_sonnet_direct_generation"
  abort "refusing non-Haiku query model #{model_id}" unless model_id.include?("claude-haiku-4-5")
  if ENV["BEDROCK_MODEL_ID"].present? && ENV["BEDROCK_MODEL_ID"].exclude?("claude-haiku-4-5")
    abort "refusing to change BEDROCK_MODEL_ID for the direct Sonnet diagnostic"
  end
  FieldCompanion::F1SonnetDirectGeneration.install!
else
  abort "refusing non-Haiku model #{model_id}" unless model_id.include?("claude-haiku-4-5")
end

account = Account.find(4)
ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
prompt_version = ENV["F1CAL_VERSION"].presence || "f1cal.r2.a1"
block_text = Rag::DocumentIdentityScope::APPLICABILITY_BLOCK
block_sha = Digest::SHA256.hexdigest(block_text)
generation_model = sonnet_direct_requested ? FieldCompanion::F1SonnetDirectGeneration::MODEL_ID : model_id
puts "account=#{account.id} #{account.slug} query_model=#{model_id} generation_model=#{generation_model} prompt_version=#{prompt_version} score=#{Score::SCORE_REVISION} block_chars=#{block_text.length} block_sha=#{block_sha}"

def fixture_result(account_id:, manual:)
  metadata = {
    "account_id" => account_id.to_s,
    "canonical_name" => Corpus.fixture_name(manual),
    "page_number" => Corpus.fixture_page(manual),
    "original_source_uri" => Corpus::PIN,
    "section_identity" => Corpus.fixture_name(manual),
    "aliases" => [ Corpus.fixture_name(manual) ]
  }
  hit = OpenStruct.new(
    content: OpenStruct.new(text: Corpus.fixture_body(manual)),
    score: 0.42,
    location: OpenStruct.new(s3_location: OpenStruct.new(uri: Corpus::PIN)),
    metadata: metadata
  )
  OpenStruct.new(retrieval_results: [ hit ])
end

def known_identity(row)
  return nil if row[:known_manufacturer].blank?

  model = row[:known_model]
  Rag::EquipmentIdentity.new(
    manufacturer: row[:known_manufacturer],
    needles: [ row[:known_manufacturer], model ],
    facts: [
      { "slot" => "manufacturer", "value" => row[:known_manufacturer], "source" => "user", "correlation_id" => "f1cal:#{model}" },
      { "slot" => "model", "value" => model, "source" => "user", "correlation_id" => "f1cal:#{model}" }
    ]
  )
end

cases = Corpus.cases.map { |row| row.merge(equipment_identity: known_identity(row)) }
only = ENV["F1CAL_IDS"].to_s.split(",").map(&:strip).compact_blank
lanes = ENV["F1CAL_LANES"].to_s.split(",").map(&:strip).compact_blank
cases.select! { |row| only.empty? || only.include?(row[:id]) }
cases.select! { |row| lanes.empty? || lanes.include?(row[:lane].to_s) }
cases.select! { |row| ENV["F1CAL_UNKNOWN_ONLY"] != "1" || row[:identity] == "unknown" }

retrieve_calls = []
rag_calls = []
F1CAL_PROMPTS = []
F1CAL_MODEL = []
jobs = []

BedrockRagService.class_eval do
  alias_method :f1cal_retrieve_with_retry, :retrieve_with_retry unless method_defined?(:f1cal_retrieve_with_retry)
  alias_method :f1cal_rag_with_retry, :retrieve_and_generate_with_retry unless method_defined?(:f1cal_rag_with_retry)
  define_method(:retrieve_with_retry) do |params|
    retrieve_calls << params
    fixture_result(account_id: account.id, manual: Thread.current[:f1cal_manual])
  end
  define_method(:retrieve_and_generate_with_retry) do |params|
    rag_calls << params
    f1cal_rag_with_retry(params)
  end
end

AiProvider.prepend(Module.new do
  def query(prompt, **)
    F1CAL_PROMPTS << prompt.to_s
    text = super
    F1CAL_MODEL << text.to_s
    text
  end
end)

original_track = TrackBedrockQueryJob.method(:perform_later)
TrackBedrockQueryJob.define_singleton_method(:perform_later) do |**kwargs|
  jobs << kwargs
  original_track.call(**kwargs)
end

def percentile(values, pct)
  sorted = values.compact.sort
  return 0 if sorted.empty?

  sorted[((pct / 100.0) * (sorted.length - 1)).round]
end

def bucket(rows, ids, lane: nil)
  selected = rows.select { |row| ids.include?(row[:id]) && row[:identity] == "unknown" }
  selected = selected.select { |row| row[:lane] == lane } if lane
  {
    n: selected.size,
    guard: selected.count { |row| row[:guard_held] },
    useful: selected.count { |row| row[:useful] },
    qualified_reference: selected.count { |row| row[:qualified_reference] },
    step_list: selected.count { |row| row[:qualified_foreign_step_list] },
    abstain: selected.count { |row| row[:abstain] },
    withheld: selected.count { |row| row[:generic_withheld] },
    unsafe: selected.count { |row| row[:unsafe_publication] },
    formulaic: selected.count { |row| row[:formulaic] }
  }
end

cap = ENV.fetch("F1CAL_SPEND_CAP", "1.0").to_f
ledger_path = Rails.root.join(ENV.fetch("F1CAL_LEDGER", "tmp/f1cal/aprime_ledger.json"))
FileUtils.mkdir_p(ledger_path.dirname)
ledger = File.exist?(ledger_path) ? JSON.parse(File.read(ledger_path)) : { "usd" => 0.0, "runs" => [] }
spent = ledger["usd"].to_f
rates = if grok_requested
  FieldCompanion::F1GrokGeneration::PRICING
elsif sonnet_requested
  FieldCompanion::F1SonnetGeneration::PRICING
elsif sonnet_direct_requested
  FieldCompanion::F1SonnetDirectGeneration::PRICING
else
  BedrockQuery::BEDROCK_PRICING[model_id] || { input: 0.0, output: 0.0 }
end
abort "refusing zero input price for #{model_id}" if rates[:input].to_f <= 0
if sonnet_requested || sonnet_direct_requested
  haiku_rates = BedrockQuery::BEDROCK_PRICING.fetch("global.anthropic.claude-haiku-4-5-20251001-v1:0")
  abort "refusing to price Sonnet at the Haiku rate" if rates[:input] == haiku_rates[:input] && rates[:output] == haiku_rates[:output]
end
per_case = if grok_requested
  0.05
elsif sonnet_requested || sonnet_direct_requested
  0.04
else
  0.006
end
projected = cases.size * per_case
if spent + projected > cap
  abort "projected spend #{format('%.3f', spent + projected)} exceeds cap #{cap}; not calling Bedrock"
end

rows = []
latencies = []
stopped = nil
verbatim_marker = "reproduce that string exactly as printed"
cases.each do |row|
  if spent >= cap
    stopped = "spend_cap"
    break
  end
  Thread.current[:f1cal_manual] = row[:manual]
  before_retrieve = retrieve_calls.size
  before_rag = rag_calls.size
  before_prompt = F1CAL_PROMPTS.size
  before_model = F1CAL_MODEL.size
  before_job = jobs.size
  before_grok = Array(Thread.current[:f1_grok_calls]).size
  before_sonnet = Array(Thread.current[:f1_sonnet_calls]).size
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = if row[:lane] == :managed
    BedrockRagService.new(account: account).query(
      row[:question],
      entity_s3_uris: [ Corpus::PIN ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: row[:locale],
      output_channel: :web,
      equipment_identity: row[:equipment_identity],
      include_diagnostics: true,
      correlation_id: "f1cal:#{prompt_version}:#{row[:id]}:#{row[:lane]}"
    )
  else
    Rag::StructuredEvidenceRoute.new(
      question: row[:question],
      account: account,
      entity_s3_uris: [ Corpus::PIN ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: row[:locale],
      equipment_identity: row[:equipment_identity],
      correlation_id: "f1cal:#{prompt_version}:#{row[:id]}:#{row[:lane]}"
    ).execute.result
  end
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  latencies << elapsed
  case_jobs = jobs[before_job..]
  model_raw = F1CAL_MODEL[before_model..]&.last.to_s
  raw = result.dig(:diagnostics, :raw_answer).presence || model_raw
  published = result[:answer].to_s
  prod_violation = result[:applicability_violation] || result.dig(:diagnostics, :applicability_violation)
  basis = result[:applicability_violation_basis] || result.dig(:diagnostics, :applicability_violation_basis)
  identity_status = result[:equipment_identity_status]
  route_outcome = result[:route_outcome]
  unknown = row[:identity] == "unknown"
  scored = Score.score_publish(row[:id], row[:question], published, route_outcome)
  withheld = Score.withheld?(published)
  abstain = !withheld && Score.abstained_text?(published, route_outcome)
  guard_held = unknown && withheld
  unsafe = unknown && scored[:unsafe_publication]
  outcome = if unsafe
    "unsafe"
  elsif guard_held
    "withheld"
  elsif abstain
    "abstain"
  else
    "publish"
  end
  useful = outcome == "publish" && unknown && scored[:useful]
  input_tokens = case_jobs.sum { |job| job[:input_tokens].to_i }
  output_tokens = case_jobs.sum { |job| job[:output_tokens].to_i }
  cache_read_tokens = case_jobs.sum { |job| job[:cache_read_tokens].to_i }
  cache_creation_tokens = case_jobs.sum { |job| job[:cache_creation_tokens].to_i }
  grok_meta = Array(Thread.current[:f1_grok_calls])[before_grok..]
  sonnet_meta = Array(Thread.current[:f1_sonnet_calls])[before_sonnet..]
  usd = (input_tokens / 1000.0 * rates[:input].to_f) +
    (output_tokens / 1000.0 * rates[:output].to_f) +
    (cache_read_tokens / 1000.0 * rates[:cache_read].to_f) +
    (cache_creation_tokens / 1000.0 * rates[:cache_creation].to_f)
  spent += usd
  sent_prompt = F1CAL_PROMPTS[before_prompt..]&.last.to_s
  record = {
    id: row[:id], lane: row[:lane].to_s, identity: row[:identity], prompt_version: prompt_version,
    score_revision: Score::SCORE_REVISION,
    question: row[:question], raw: raw, published: published,
    applicability_violation: prod_violation&.to_s, basis: basis&.to_s,
    guard_held: guard_held, outcome: outcome, useful: useful,
    qualified_reference: outcome == "publish" && unknown && scored[:qualified_reference],
    qualified_foreign_step_list: outcome == "publish" && unknown && scored[:qualified_foreign_step_list],
    abstain: abstain, unsafe_publication: unsafe, formulaic: outcome == "publish" && unknown && scored[:formulaic],
    generic_withheld: withheld, identity_status: identity_status&.to_s,
    retrieves: retrieve_calls.size - before_retrieve, rag: rag_calls.size - before_rag,
    generation_count: case_jobs.size, input_tokens: input_tokens, output_tokens: output_tokens,
    cache_read_tokens: cache_read_tokens,
    cache_creation_tokens: cache_creation_tokens,
    returned_model: sonnet_meta.last&.dig(:returned_model),
    reasoning_tokens: grok_meta.filter_map { |meta| meta[:reasoning_tokens] }.presence&.sum,
    reasoning_chars: grok_meta.sum { |meta| meta[:reasoning_chars].to_i },
    latency_ms: elapsed, usd: usd.round(6),
    routes: case_jobs.map { |job| job[:route] },
    outcome_reason: result.dig(:diagnostics, :outcome_reason) || result[:equipment_identity_reason],
    route_outcome: route_outcome&.to_s,
    prompt_has_applicability_block: sent_prompt.include?("identity_unknown_reference"),
    prompt_has_verbatim_directive: sent_prompt.include?(verbatim_marker)
  }
  rows << record
  puts "#{record[:id]} #{record[:lane]} #{record[:outcome]} useful=#{useful} guard=#{guard_held} unsafe=#{unsafe} formulaic=#{record[:formulaic]} #{elapsed}ms $#{format('%.4f', usd)} spent=#{format('%.4f', spent)}"
end

unknown_ids = rows.select { |row| row[:identity] == "unknown" }.pluck(:id).uniq
summary = {
  prompt_version: prompt_version,
  score_revision: Score::SCORE_REVISION,
  block_sha: block_sha,
  block_chars: block_text.length,
  head: `git rev-parse HEAD`.strip,
  model: generation_model,
  production_query_model: BedrockClient::QUERY_MODEL_ID,
  transport: sonnet_direct_requested ? "anthropic_messages" : "bedrock",
  reasoning_effort: grok_requested ? FieldCompanion::F1GrokGeneration::REASONING_EFFORT : nil,
  thinking_type: if sonnet_requested
                   FieldCompanion::F1SonnetGeneration::THINKING_TYPE
                 elsif sonnet_direct_requested
                   FieldCompanion::F1SonnetDirectGeneration::THINKING_TYPE
                 end,
  returned_models: rows.filter_map { |row| row[:returned_model] }.uniq,
  input_usd_per_1k: rates[:input],
  output_usd_per_1k: rates[:output],
  cache_read_usd_per_1k: rates[:cache_read],
  cache_creation_usd_per_1k: rates[:cache_creation],
  stopped: stopped,
  executions: rows.size,
  retrieves: retrieve_calls.size,
  rag: rag_calls.size,
  generations: jobs.size,
  input_tokens: rows.sum { |row| row[:input_tokens] },
  output_tokens: rows.sum { |row| row[:output_tokens] },
  cache_read_tokens: rows.sum { |row| row[:cache_read_tokens].to_i },
  cache_creation_tokens: rows.sum { |row| row[:cache_creation_tokens].to_i },
  reasoning_tokens: rows.filter_map { |row| row[:reasoning_tokens] }.presence&.sum,
  reasoning_chars: rows.sum { |row| row[:reasoning_chars].to_i },
  usd: rows.sum { |row| row[:usd] }.round(6),
  p50_ms: percentile(latencies, 50),
  p95_ms: percentile(latencies, 95),
  min_ms: latencies.min,
  max_ms: latencies.max,
  s1: bucket(rows, Corpus::S1),
  s2: bucket(rows, Corpus::S2),
  s3: bucket(rows, unknown_ids - Corpus::S1 - Corpus::S2),
  unknown: bucket(rows, unknown_ids),
  managed: bucket(rows, unknown_ids, lane: "managed"),
  structured: bucket(rows, unknown_ids, lane: "structured"),
  known: rows.select { |row| Corpus::KNOWN.include?(row[:id]) }.map { |row|
    { id: row[:id], lane: row[:lane], status: row[:identity_status], outcome: row[:outcome],
      block: row[:prompt_has_applicability_block], verbatim: row[:prompt_has_verbatim_directive],
      step_list: Score.step_list?(row[:published]), published: row[:published].to_s.tr("\n", " ")[0, 240] }
  }
}
out = ENV["F1CAL_OUT"].presence || "tmp/f1cal/runs/#{prompt_version}.json"
path = Rails.root.join(out)
FileUtils.mkdir_p(path.dirname)
File.write(path, JSON.pretty_generate(rows: rows, summary: summary))
ledger["usd"] = spent.round(6)
ledger["runs"] << { "version" => prompt_version, "usd" => summary[:usd], "executions" => rows.size, "stopped" => stopped, "at" => Time.now.utc.iso8601 }
File.write(ledger_path, JSON.pretty_generate(ledger))
puts JSON.pretty_generate(summary)
puts "wrote #{out} aprime_cumulative_usd=#{format('%.6f', spent)}"
exit(stopped ? 2 : 0)
