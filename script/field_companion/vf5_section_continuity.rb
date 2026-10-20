# frozen_string_literal: true

require "digest"
require "json"
require "open3"

# Repairs the cross-page item in the captured D-histórico turn-1 prompt and,
# when VF5_SECTION_CONTINUITY=1, asks Haiku for three independent samples.
# Without that flag this only writes the repaired prompt, diffs, and the
# rubric. The assignment ledger is never reset. No Retrieve and no KB write.

RESERVE_CALLS = 15
CALL_CAP = 96
COST_CAP = BigDecimal("4")
JOB_CALLS = 10
JOB_USD = BigDecimal("0.50")
EXPECTED_ATTEMPTS = 55
EXPECTED_COMMITTED = BigDecimal("0.773828")
EXPECTED_PROMPT_SHA = "a3dc05933eaa46bfb7af798f41992660e438e6f3575e50973af4871184564754"
EXPECTED_BODY_SHA = "3a0f1c55a52b0ce56b056488a9ec05541c36e018ab9169d4f741aa4d7522f25a"
EXPECTED_PDF_SHA = "be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72"
CONTROL_PATH = "tmp/field_companion/vf5_fidelity_replay/vf5-fidelity-D-historico-20261020T202806Z/t1/attempt-1/bodies/b0001.txt"
PDF_PATH = "docs/field_companion/fuentes/VF5.pdf"
RAW_PAGE_PATH = "tmp/field_companion/local_ingestion/raw-p13.txt"
SPEND_PATH = "tmp/field_companion/vf5_generator_benchmark/assignment_spend.json"
MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
REQUEST_ID = "354da85f-c20c-4d36-bb88-45a0c059bc2e"
# Frozen before any generation. Do not edit after the samples exist.
RUBRIC = {
  "documentary" => [
    "Las tres comprobaciones iniciales conservan su significado.",
    "TEST aparece como prueba posterior pendiente, condicionada a que el problema persista.",
    "Se conserva el resultado documental: si no completa apertura o cierre en esa prueba, el manual señala obstrucción.",
    "Las citas corresponden a los fragmentos realmente usados."
  ],
  "case" => [
    "La observación visual no descarta globalmente la obstrucción.",
    "No se atribuye al técnico una comprobación documental realizada que no reportó. Se puede reconocer su observación visual, conservando su alcance.",
    "No se inventa el significado eléctrico del LED.",
    "No se prescribe ajustar #54 ni otro procedimiento que los pasajes no documenten.",
    "No se prioriza una causa sin respaldo.",
    "SW4 puede explicarse documentalmente; su ejemplo no se presenta como mecanismo confirmado de esta puerta.",
    "No se inventan mediciones, reparaciones ni resultados."
  ],
  "reading" => [
    "Es válido decir tres comprobaciones iniciales y, si persiste, una prueba adicional. No se exige una lista plana de cuatro ni palabras literales.",
    "«Para descartar» no invierte el manual por sí solo. Se mira si extrapola una conclusión que el pasaje no permite.",
    "«Eso explicaría» puede ser una hipótesis si está presentada como posibilidad y no presupone hechos no confirmados.",
    "No se penaliza estilo, encabezados o formulaciones equivalentes.",
    "No se rebajan los criterios para obtener un pase."
  ]
}.freeze

def vf5_section_continuity_main
  ENV["VF5_FIDELITY_REPLAY_REQUIRE"] = "1"
  load Rails.root.join("script/field_companion/vf5_fidelity_replay.rb")
  raise "production" if Rails.env.production?

  control = Rails.root.join(CONTROL_PATH).read
  vf5_section_control!(control)
  pages = vf5_section_pages
  records = vf5_section_records
  repaired = SectionPageContinuity.repair_prompt(control, pages: pages, extra_records: records)
  pipeline = SectionPageContinuity.repair_prompt(control, pages: pages, extra_records: records, isolate: false)
  vf5_section_authorize!(control, repaired, pipeline, pages, records)

  live = ENV["VF5_SECTION_CONTINUITY"] == "1"
  run_id = live ? "vf5-section-continuity-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}" : "preview"
  root = Rails.root.join("tmp/field_companion/vf5_section_continuity/#{run_id}")
  root.mkpath
  balance = vf5_section_balance
  vf5_section_write!(root, control, repaired, pipeline, pages, records, balance, live)
  puts JSON.generate("status" => "prepared", "run_id" => run_id, "balance" => balance.except("entries"))
  return 0 unless live

  vf5_section_refuse_budget!(balance)
  code = vf5_section_execute(root, run_id, repaired.fetch("prompt"), balance)
  puts JSON.generate("status" => "finished", "exit" => code, "run_id" => run_id)
  code
end

def vf5_section_control!(control)
  raise "control sha" unless Digest::SHA256.hexdigest(control) == EXPECTED_PROMPT_SHA

  body = Rag::CapturedGenerationReplay.invoke_body_json(prompt: control, max_tokens: 3000, temperature: 0.1, system: nil)
  raise "body sha" unless Digest::SHA256.hexdigest(body) == EXPECTED_BODY_SHA
  raise "pdf sha" unless Digest::SHA256.file(Rails.root.join(PDF_PATH)).hexdigest == EXPECTED_PDF_SHA
end

def vf5_section_pages
  [ 12, 13 ].index_with { |number| vf5_section_page(number) }
end

def vf5_section_page(number)
  output, status = Open3.capture2("pdftotext", "-layout", "-f", number.to_s, "-l", number.to_s, Rails.root.join(PDF_PATH).to_s, "-")
  raise "pdftotext #{number}" unless status.success? && output.present?

  output
end

def vf5_section_records
  JSON.parse(Rails.root.join(RAW_PAGE_PATH).read).fetch("chunks").flat_map { |chunk| Array(chunk["field_records"]) }
end

def vf5_section_authorize!(control, repaired, pipeline, pages, records)
  raise repaired["blocked"].to_s unless repaired["blocked"].nil?

  note = repaired["notes"].find { |item| item["joined"] }
  raise "not joined" unless note
  raise "section" unless note["section"] == "8.2 Funcionamiento normal"
  raise "printed" unless note["printed_pages"] == [ "11/21", "12/21" ]
  raise "rejected" unless note["rejected_records"].empty?
  raise "moved" unless note["moved_records"] == 1

  before = vf5_section_contents(control)
  after = vf5_section_contents(repaired.fetch("prompt"))
  raise "result count" unless before.size == 3 && after.size == 3
  raise "outside" unless vf5_section_outside(control) == vf5_section_outside(repaired.fetch("prompt"))
  raise "result 3" unless before[2] == after[2]

  line = before[1].lines.find { |item| item.include?("En caso que el problema persista") }
  raise "continuation line" unless line&.start_with?("– ")
  raise "result 2" unless after[1] == before[1].sub("#{line}\n", "")
  raise "duplicated" unless after[0].scan("En caso que el problema persista").size == 2
  raise "child keeps continuation" if after[1].include?("En caso que el problema persista")

  parent = after[0]
  narrative = parent.sub(/\n# FIELD-SAFETY EVIDENCE RECORDS.*\z/m, "")
  raise "narrative copies" unless narrative.scan("En caso que el problema persista").size == 1
  %w[8.2\ Funcionamiento\ normal •\ La\ puerta\ se\ re-abre\ sola. [PDF_PAGE:\ 12] [PRINTED_PAGE:\ 11/21] [PDF_PAGE:\ 13] [PRINTED_PAGE:\ 12/21]].each do |needle|
    raise "missing #{needle}" unless parent.include?(needle)
  end
  [
    "– Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).",
    "– Comprobar que la fotocélula no esté activada.",
    "– Comprobar que no hay una obstrucción mecánica en la puerta."
  ].each { |check| raise "check" unless parent.include?(check) }
  raise "next symptom" if parent.include?("La puerta no alcanza la posición de apertura completa")
  raise "status alias" if parent.include?("LED STATUS") || parent.include?("fusibles")
  raise "state" if repaired.fetch("prompt").include?("Reportado por el técnico:")
  raise "aliases" unless parent.include?(before[0][/\[SEARCH_ALIASES:.*\]/])

  record = records.find { |item| item["a"].to_s.include?("En caso que el problema persista") }
  raise "source record" unless record && record["k"] == "TROUBLESHOOTING_STEP"
  raise "action" unless parent.include?("ACTION: #{record['a']}")
  raise "result" unless parent.include?("EXPECTED_RESULT: #{record['r']}")
  raise "condition" unless record["a"].start_with?("En caso que") && record["r"].start_with?("Si ")
  vf5_section_ids!(parent, record)
  vf5_section_pdf!(pages, line)

  pipe = vf5_section_contents(pipeline.fetch("prompt"))
  raise "pipeline child" if pipe[1] == after[1]
  raise "pipeline sent" if repaired.fetch("prompt") == pipeline.fetch("prompt")
end

def vf5_section_ids!(parent, record)
  heading = "8.2 Funcionamiento normal — La puerta se re-abre sola."
  parser = BatchResultsParserService.new(s3_service: :local)
  fourth = parser.send(
    :field_record_id,
    page: 13,
    source: heading,
    record_type: record["k"],
    action: record["a"],
    expected_result: record["r"],
    evidence: record["ev"]
  )
  raise "fourth id" unless parent.include?("RECORD_ID: #{fourth}")

  [
    [ "Si la puerta se re-abre sola: comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)", "Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)" ],
    [ "Si la puerta se re-abre sola: comprobar que la fotocélula no esté activada", "Comprobar que la fotocélula no esté activada" ],
    [ "Si la puerta se re-abre sola: comprobar que no hay una obstrucción mecánica en la puerta", "Comprobar que no hay una obstrucción mecánica en la puerta" ]
  ].each do |action, evidence|
    identifier = parser.send(
      :field_record_id,
      page: 12,
      source: heading,
      record_type: "TROUBLESHOOTING_STEP",
      action: action,
      expected_result: "DATA_NOT_AVAILABLE",
      evidence: evidence
    )
    raise "check id" unless parent.include?("RECORD_ID: #{identifier}")
    raise "check action" unless parent.include?("ACTION: #{action}")
  end
end

def vf5_section_pdf!(pages, line)
  page12 = vf5_section_flat(pages.fetch(12))
  page13 = vf5_section_flat(pages.fetch(13))
  raise "printed 12" unless pages.fetch(12).include?("Pág. 11 / 21")
  raise "printed 13" unless pages.fetch(13).include?("Pág. 12 / 21")
  raise "section on page" unless page12.include?("8.2 Funcionamiento normal")
  [
    "Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).",
    "Comprobar que la fotocélula no esté activada.",
    "Comprobar que no hay una obstrucción mecánica en la puerta."
  ].each { |check| raise "pdf check" unless page12.include?(check) }
  sentence = vf5_section_flat(line)
  raise "pdf continuation" unless page13.include?(sentence.delete_prefix("– ").strip)
  raise "pdf owns continuation" if page12.include?("En caso que el problema persista")
end

def vf5_section_flat(text)
  text.to_s.gsub(/\s+/, " ").strip
end

def vf5_section_contents(text)
  text.to_enum(:scan, SectionPageContinuity::RESULT_PATTERN).map { Regexp.last_match[1] }
end

def vf5_section_outside(text)
  text.gsub(SectionPageContinuity::RESULT_PATTERN, "<RESULT>")
end

def vf5_section_balance
  raw = JSON.parse(Rails.root.join(SPEND_PATH).read)
  open = raw["open"].is_a?(Hash) ? raw["open"] : {}
  held = open.values.sum(BigDecimal("0")) { |amount| BigDecimal(amount.to_s) }
  balance = {
    "attempts" => raw["attempts"].to_i,
    "blocked" => raw["blocked"].to_i,
    "priced" => raw["priced"].to_i,
    "committed_usd" => format("%.6f", BigDecimal(raw["committed"].to_s)),
    "unknown_usd" => format("%.6f", BigDecimal(raw["unknown"].to_s)),
    "held_usd" => format("%.6f", held),
    "open_holds" => open.size,
    "entries" => raw["entries"].is_a?(Array) ? raw["entries"].size : nil
  }
  raise "attempts #{balance['attempts']}" unless balance["attempts"] == EXPECTED_ATTEMPTS
  raise "committed" unless BigDecimal(balance["committed_usd"]) == EXPECTED_COMMITTED
  raise "unknown" unless BigDecimal(balance["unknown_usd"]).zero?
  raise "holds" unless balance["open_holds"].zero?

  balance
end

def vf5_section_write!(root, control, repaired, pipeline, pages, records, balance, live)
  prompt = repaired.fetch("prompt")
  root.join("prompt-before.txt").write(control)
  root.join("prompt-after.txt").write(prompt)
  root.join("prompt-pipeline.txt").write(pipeline.fetch("prompt"))
  root.join("notes.json").write(JSON.generate(repaired["notes"]))
  root.join("pipeline-notes.json").write(JSON.generate(pipeline["notes"]))
  root.join("rubric.json").write(JSON.pretty_generate(RUBRIC))
  root.join("balance_before.json").write(JSON.generate(balance))
  pages.each { |number, text| root.join("page-#{number}.txt").write(text) }
  record = records.find { |item| item["a"].to_s.include?("En caso que el problema persista") }
  root.join("source-record.json").write(JSON.pretty_generate(record))
  before = vf5_section_contents(control)
  after = vf5_section_contents(prompt)
  pipe = vf5_section_contents(pipeline.fetch("prompt"))
  3.times do |index|
    root.join("result-#{index}-before.txt").write(before[index])
    root.join("result-#{index}-after.txt").write(after[index])
    vf5_section_diff(root.join("result-#{index}-before.txt"), root.join("result-#{index}-after.txt"), root.join("diff-result-#{index}.diff"))
  end
  vf5_section_diff(root.join("prompt-before.txt"), root.join("prompt-after.txt"), root.join("diff-prompt.diff"))
  root.join("result-1-pipeline.txt").write(pipe[1])
  vf5_section_diff(root.join("result-1-after.txt"), root.join("result-1-pipeline.txt"), root.join("diff-pipeline-result-1.diff"))
  body = Rag::CapturedGenerationReplay.invoke_body_json(prompt: prompt, max_tokens: 3000, temperature: 0.1, system: nil)
  root.join("body-after.json").write(body)
  root.join("manifest.json").write(JSON.pretty_generate(vf5_section_manifest(prompt, body, balance, live)))
end

def vf5_section_diff(left, right, path)
  output, status = Open3.capture2("diff", "-u", left.to_s, right.to_s)
  raise "diff" unless status.success? || status.exitstatus == 1

  path.write(output)
end

def vf5_section_manifest(prompt, body, balance, live)
  {
    "live" => live,
    "head" => `git rev-parse HEAD`.strip,
    "control_path" => CONTROL_PATH,
    "raw_page_path" => RAW_PAGE_PATH,
    "pdf_sha256" => EXPECTED_PDF_SHA,
    "control_prompt_sha256" => EXPECTED_PROMPT_SHA,
    "control_body_sha256" => EXPECTED_BODY_SHA,
    "prompt_sha256" => Digest::SHA256.hexdigest(prompt),
    "body_sha256" => Digest::SHA256.hexdigest(body),
    "model_id" => MODEL_ID,
    "temperature" => 0.1,
    "max_tokens" => 3000,
    "system" => "absent",
    "anthropic_version" => Rag::CapturedGenerationReplay::ANTHROPIC_VERSION,
    "parse_calls" => 0,
    "samples" => 3,
    "attempt_limit" => Rag::TransientBackoff.limit,
    "sdk_max_attempts" => 1,
    "selection" => "Eval prompt uses isolate. Result 2 loses only the continuation sentence. Its aliases and records stay. isolate:false retargets the other symptoms' placeholder headings and is saved as prompt-pipeline.txt. It is not sent.",
    "balance_before" => balance,
    "rubric_sha256" => Digest::SHA256.hexdigest(JSON.generate(RUBRIC)),
    "job_calls" => JOB_CALLS,
    "job_usd" => JOB_USD.to_s("F"),
    "reserve_calls" => RESERVE_CALLS
  }
end

def vf5_section_refuse_budget!(balance)
  remaining_calls = CALL_CAP - balance["attempts"]
  remaining_usd = COST_CAP - BigDecimal(balance["committed_usd"]) - BigDecimal(balance["unknown_usd"])
  raise "reserve" if remaining_calls < RESERVE_CALLS + JOB_CALLS
  raise "global cost" if remaining_usd < JOB_USD
end

def vf5_section_execute(root, run_id, prompt, balance)
  results = []
  ENV.delete("RAG_ASSIGNMENT_SPEND_PATH")
  spend = Rag::AssignmentSpend.new(path: Rails.root.join(SPEND_PATH), call_cap: CALL_CAP, cost_cap_usd: COST_CAP)
  ENV["RAG_LOCAL_PASS_GUARD"] = "1"
  ENV["RAG_LOCAL_PASS_CALL_CAP"] = JOB_CALLS.to_s
  ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = JOB_USD.to_s("F")
  ENV["AWS_MAX_ATTEMPTS"] = "1"
  Rag::LocalPassLedger.reset!
  Rag::LocalPassLedger.reset_local_process!
  raise "ledger #{Rag::LocalPassLedger.missing_requirements.join(' ')}" unless Rag::LocalPassLedger.armed?

  client = vf5_benchmark_client
  max_attempts = client.instance_variable_get(:@client).config.max_attempts
  raise "max_attempts #{max_attempts}" unless max_attempts == 1

  prepared = vf5_section_prepared(prompt)
  3.times do |index|
    name = "s#{index + 1}"
    directory = root.join(name)
    directory.mkpath
    directory.join("checkpoint.json").write(JSON.generate(
      "sample" => name,
      "prompt_sha256" => prepared.prompt_sha256,
      "body_sha256" => prepared.body_sha256,
      "model_id" => MODEL_ID,
      "temperature" => prepared.temperature,
      "max_tokens" => prepared.max_tokens,
      "system" => nil
    ))
    unless vf5_section_room?(spend, balance)
      results << { "sample" => name, "status" => "not_started", "reason" => "cap" }
      break
    end
    sample = Rag::CapturedGenerationReplay.run_sample(
      prepared: prepared,
      model_id: MODEL_ID,
      client: client,
      spend: spend,
      output_dir: directory,
      run_id: run_id,
      correlation_prefix: "vf5-section:#{name}",
      attempt_limit: Rag::TransientBackoff.limit
    )
    results << vf5_section_sample(name, sample, prepared)
    break unless sample.status == "returned"
  end
  results.count { |row| row["status"] == "returned" } == 3 ? 0 : 2
rescue Rag::AssignmentSpend::Stop, Rag::LocalPassLedger::Stop => error
  results << { "status" => "stopped", "reason" => error.message }
  2
ensure
  if defined?(results) && results && root
    final_balance = vf5_section_balance_now
    root.join("balance_after.json").write(JSON.generate(final_balance))
    root.join("results.json").write(JSON.generate("results" => results, "balance_after" => final_balance))
  end
end

def vf5_section_prepared(prompt)
  replay = Rag::CapturedGenerationReplay
  body = replay.invoke_body_json(prompt: prompt, max_tokens: 3000, temperature: 0.1, system: nil)
  replay::Prepared.new(
    turn: 1,
    request_id: REQUEST_ID,
    prompt: prompt,
    prompt_sha256: Digest::SHA256.hexdigest(prompt),
    system: nil,
    system_sha256: nil,
    temperature: 0.1,
    max_tokens: 3000,
    anthropic_version: replay::ANTHROPIC_VERSION,
    messages: [ { "role" => "user" } ],
    captured_model_id: MODEL_ID,
    correlation_id: nil,
    body_json: body,
    body_sha256: Digest::SHA256.hexdigest(body)
  )
end

def vf5_section_room?(spend, opening)
  snap = spend.snapshot
  used = snap["attempts"].to_i - opening["attempts"]
  spent = BigDecimal(snap["committed_usd"]) + BigDecimal(snap["unknown_usd"].to_s) + BigDecimal(snap["held_usd"].to_s) - BigDecimal(opening["committed_usd"])
  used < JOB_CALLS && spent < JOB_USD && snap["attempts"].to_i < CALL_CAP - RESERVE_CALLS
end

def vf5_section_sample(name, sample, prepared)
  raise "prompt drifted" unless sample.prompt_sha256 == prepared.prompt_sha256
  raise "body drifted" unless sample.body_sha256 == prepared.body_sha256

  {
    "sample" => name,
    "status" => sample.status,
    "attempts" => sample.attempts,
    "input_tokens" => sample.input_tokens,
    "output_tokens" => sample.output_tokens,
    "latency_ms" => sample.latency_ms,
    "cost_usd" => sample.cost_usd,
    "prompt_sha256" => sample.prompt_sha256,
    "body_sha256" => sample.body_sha256,
    "error_class" => sample.error_class,
    "error_message" => sample.error_message,
    "output_dir" => sample.output_dir
  }
end

def vf5_section_balance_now
  raw = JSON.parse(Rails.root.join(SPEND_PATH).read)
  open = raw["open"].is_a?(Hash) ? raw["open"] : {}
  held = open.values.sum(BigDecimal("0")) { |amount| BigDecimal(amount.to_s) }
  {
    "attempts" => raw["attempts"].to_i,
    "blocked" => raw["blocked"].to_i,
    "priced" => raw["priced"].to_i,
    "committed_usd" => format("%.6f", BigDecimal(raw["committed"].to_s)),
    "unknown_usd" => format("%.6f", BigDecimal(raw["unknown"].to_s)),
    "held_usd" => format("%.6f", held),
    "open_holds" => open.size
  }
rescue StandardError => error
  { "unreadable" => error.message }
end

unless ENV["VF5_SECTION_CONTINUITY_REQUIRE"] == "1"
  code = vf5_section_continuity_main
  exit code unless code.zero?
end
