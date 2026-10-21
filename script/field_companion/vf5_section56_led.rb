# frozen_string_literal: true

require "digest"
require "json"
require "open3"

# Marks search result 4 of the section 5.6 replay with the applicability line
# DocumentIdentityScope produces for that same VF5 chunk, then, when
# VF5_SECTION56_LED=1, asks Haiku for three independent samples. Without that
# flag this only writes the prompt, the diff, the provenance, and the rubric.
# The assignment ledger is never reset. No Retrieve, no interpreter, and no
# knowledge-base write.
#
# Boot with KNOWLEDGE_BASE_S3_BUCKET set to the chunk URI's bucket. A relative
# catalog key is expanded with that constant. The dev bucket does not match
# this chunk and the same call then returns reference-only. That is not the
# assembly that labeled results 1-3.

RESERVE_CALLS = 15
CALL_CAP = 96
COST_CAP = BigDecimal("4")
JOB_CALLS = 3
JOB_USD = BigDecimal("0.16")
EXPECTED_ATTEMPTS = 61
EXPECTED_COMMITTED = BigDecimal("0.841346")
EXPECTED_BASE_SHA = "7dd848fca0b780694c2b5ad7749271d54a885b82ea6afeab1872dbfa5bc64873"
EXPECTED_PDF_SHA = "be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72"
EXPECTED_CHUNK_SHA = "02944c035917290906ce3254e06d72b773fe7617044fd7d0468d6dad7550cc21"
EXPECTED_PAGE7_META_SHA = "337e3c286fa9ed82019ed5b78fae0d26b46281aa9db775c0beed6f6e7e5be7de"
EXPECTED_PAGE12_META_SHA = "04f392c0bf1295fd6cfa8880cc08df312dfda58ca71297f88038ebb1d7dca3df"
BASE_PATH = "tmp/field_companion/vf5_section56/vf5-section56-20261020T232307Z/prompt-after.txt"
PDF_PATH = "docs/field_companion/fuentes/VF5.pdf"
CAPTURE_DIR = "tmp/field_companion/validation_captures/vf5-codefix-20261020T1644Z/c183d77a-c39e-48ae-8c0d-8728e266ece5"
CHUNK_PATH = "#{CAPTURE_DIR}/bodies/b0003.txt"
TURN_CAPTURE = "tmp/field_companion/validation_captures/vf5-bound-20261020T1728Z/354da85f-c20c-4d36-bb88-45a0c059bc2e/capture.json"
PAGE7_META = "tmp/field_companion/vf5_section56/inputs/chunk_p7_3.metadata.json"
PAGE12_META = "tmp/field_companion/vf5_section56/inputs/chunk_p12_1.metadata.json"
SPEND_PATH = "tmp/field_companion/vf5_generator_benchmark/assignment_spend.json"
MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
REQUEST_ID = "354da85f-c20c-4d36-bb88-45a0c059bc2e"
DOCUMENT_ID = "be7a39a3490c92c8381cb883402760cb07d1"
CHUNK_URI = "s3://multimodal-source-destination/bulk_chunks/1/#{DOCUMENT_ID}/chunk_p7_3.txt"
SOURCE_URI = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
LED_CLAUSE = "la fotocélula o la entrada de re-apertura está activada"
MARKER = "</search_result>\n\n# LANGUAGE AND TONE\n"
# Frozen before any generation. Do not edit after the samples exist.
RUBRIC = {
  "semantic" => [
    "Explica que el LED puede corresponder a fotocélula o a entrada de reapertura activada.",
    "No afirma cuál de las dos ocurrió sin evidencia.",
    "Mantiene pendiente comprobar la fotocélula y distinguir el origen de la activación."
  ],
  "attribution" => [
    "Cita [4] para esa explicación.",
    "La cita respalda realmente la afirmación."
  ],
  "case" => [
    "La observación visual no se convierte en descarte global ni en comprobación atribuida al técnico.",
    "#54 sigue sin revisar, sin ajuste ordenado y sin valores inventados.",
    "TEST conserva la condición documental de persistencia y no queda restringido a revisar #54.",
    "No aparece un orden obligatorio inventado.",
    "El cierre conserva los pendientes relevantes.",
    "SW4 se explica sin convertir el ejemplo en el mecanismo confirmado.",
    "No hay mediciones, reparaciones ni resultados inventados."
  ],
  "reading" => [
    "Se juzga significado y contexto. No se exige redacción literal ni se penaliza el formato.",
    "La ausencia de cita no equivale a ausencia de uso semántico. Conservar las dos alternativas sin [4] es mejora semántica y fallo de atribución.",
    "Dos o tres muestras con las dos alternativas y cita correcta son una señal inicial favorable al marcado.",
    "Uso semántico correcto sin cita es una mejora parcial, distinta del fallo anterior.",
    "Una sola muestra que mejora no alcanza para dar la mejora por estable.",
    "Ninguna mejora significa que el marcado no bastó en estas muestras. No descarta toda influencia de la marca.",
    "No se declara causa exclusiva, estabilidad estadística ni aceptación del turno 1."
  ]
}.freeze

def vf5_led_main
  ENV["VF5_GENERATOR_BENCHMARK_REQUIRE"] = "1"
  load Rails.root.join("script/field_companion/vf5_generator_benchmark.rb")
  raise "production" if Rails.env.production?

  base = Rails.root.join(BASE_PATH).binread
  chunk = Rails.root.join(CHUNK_PATH).binread
  vf5_led_bytes!(base, chunk)
  pages = vf5_led_pages
  provenance = vf5_led_provenance(chunk, pages)
  classification = vf5_led_applicability!(chunk)
  provenance["applicability"] = classification
  label = classification.fetch("label")
  prompt = vf5_led_prompt(base, label)
  vf5_led_authorize!(base, chunk, prompt, provenance, label)

  live = ENV["VF5_SECTION56_LED"] == "1"
  run_id = live ? "vf5-section56-mark-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}" : "preview-applicability"
  root = Rails.root.join("tmp/field_companion/vf5_section56/#{run_id}")
  root.mkpath
  balance = vf5_led_balance
  body = vf5_led_write!(root, base, chunk, prompt, pages, provenance, balance, live)
  puts JSON.generate("status" => "prepared", "run_id" => run_id, "balance" => balance.except("entries"), "prompt_sha256" => Digest::SHA256.hexdigest(prompt), "body_sha256" => Digest::SHA256.hexdigest(body), "ceiling_usd" => provenance["character_ceiling_usd"])
  return 0 unless live

  opening_admission = vf5_led_refuse_budget!(balance, Rag::LocalPassLedger.price(MODEL_ID, prompt.bytesize, 3000))
  root.join("admission_opening.json").write(JSON.generate(opening_admission))
  vf5_led_match_preview!(prompt)
  code = vf5_led_execute(root, run_id, prompt, balance)
  puts JSON.generate("status" => "finished", "exit" => code, "run_id" => run_id)
  code
end

def vf5_led_bytes!(base, chunk)
  raise "base encoding" unless base.dup.force_encoding(Encoding::UTF_8).valid_encoding?
  raise "chunk encoding" unless chunk.dup.force_encoding(Encoding::UTF_8).valid_encoding?
  raise "base sha" unless Digest::SHA256.hexdigest(base) == EXPECTED_BASE_SHA
  raise "chunk sha" unless Digest::SHA256.hexdigest(chunk) == EXPECTED_CHUNK_SHA
  raise "pdf sha" unless Digest::SHA256.file(Rails.root.join(PDF_PATH)).hexdigest == EXPECTED_PDF_SHA
  raise "chunk newline" if chunk.end_with?("\n")
end

def vf5_led_pages
  layout, layout_status = Open3.capture2("pdftotext", "-layout", "-f", "7", "-l", "7", Rails.root.join(PDF_PATH).to_s, "-")
  raw, raw_status = Open3.capture2("pdftotext", "-raw", "-f", "7", "-l", "7", Rails.root.join(PDF_PATH).to_s, "-")
  raise "pdftotext layout" unless layout_status.success? && layout.present?
  raise "pdftotext raw" unless raw_status.success? && raw.present?

  { "layout" => layout, "raw" => raw }
end

def vf5_led_provenance(chunk, pages)
  text = chunk.dup.force_encoding(Encoding::UTF_8)
  flat = vf5_led_flat(pages.fetch("raw"))
  capture = JSON.parse(Rails.root.join(CAPTURE_DIR, "capture.json").read)
  row_event = capture.fetch("events").find { |event| event["kind"] == "retrieval_results" && event["source"] == "publication_gate" }
  raise "retrieval row" unless row_event

  row = row_event.fetch("rows").fetch(0)
  evidence = row.fetch("text")
  raise "evidence path" unless evidence["path"] == "bodies/b0003.txt"
  raise "evidence sha" unless evidence["sha256"] == EXPECTED_CHUNK_SHA
  raise "document" unless row["document"] == "VF5"
  raise "page" unless row["page"].to_i == 7
  raise "document id" unless row["document_id"] == DOCUMENT_ID
  raise "chunk uri" unless row["uri"] == CHUNK_URI
  raise "source uri" unless text.include?("[DOCUMENT: VF5.pdf]\n[SOURCE_URI: #{SOURCE_URI}]")
  raise "pdf clause" unless flat.include?("Indicador LED y relé activado cuando #{LED_CLAUSE}.")
  raise "pdf section" unless flat.include?("5.6 Relés de salida e indicadores LED (del 30 al 41)")
  raise "printed page" unless flat.include?("Pág. 6 / 21")
  raise "row clause" unless text.include?("| FOTOCÉLULA | 36, 37, 38 | LED y relé activado cuando #{LED_CLAUSE}. |")
  raise "record action" unless text.include?("ACTION: Terminales 36-38 — relé FOTOCÉLULA: LED y relé activado cuando #{LED_CLAUSE}.")
  raise "record evidence" unless text.include?("EVIDENCE: relé activado cuando #{LED_CLAUSE}.")
  raise "record id" unless text.include?("RECORD_ID: FR-AC46C0E9AF51D3F4")

  retrieve = capture.fetch("events").find { |event| event["kind"] == "retrieve" && event["result"] == "sent" }
  web = capture.fetch("events").find { |event| event["kind"] == "web_request" }
  differences = []
  differences << "La fila dice «LED y relé» y la página dice «Indicador LED y relé». La cláusula con las dos alternativas es la misma."
  differences << "EXPECTED_RESULT comprime «entrada de re-apertura» a «re-apertura». ACTION y EVIDENCE conservan la cláusula completa." unless text.include?("EXPECTED_RESULT: Indica al controlador principal que la fotocélula o la entrada de re-apertura está activada.")
  differences << "El chunk trae REQUIRES_FIELD_VERIFICATION para los polos COM/NA/NC. Esa frase no está en el texto de la página 7." if text.include?("REQUIRES_FIELD_VERIFICATION") && flat.exclude?("REQUIRES_FIELD_VERIFICATION")
  differences << "pdftotext no lista el terminal 36. El dibujo de la página sí rotula 36, 37 y 38 en el contacto FOTOCÉLULA. La comprobación del dibujo es visual, no de este script."

  {
    "capture_dir" => CAPTURE_DIR,
    "request_key" => web&.dig("request_key"),
    "episode_id" => row_event["episode_id"],
    "session_id" => row_event["session_id"],
    "knowledge_base_id" => retrieve&.dig("knowledge_base_id"),
    "retrieval_query" => retrieve&.dig("retrieval_query"),
    "document" => row["document"],
    "document_id" => row["document_id"],
    "page" => row["page"],
    "chunk_uri" => row["uri"],
    "source_uri" => SOURCE_URI,
    "chunk_sha256" => EXPECTED_CHUNK_SHA,
    "pdf_sha256" => EXPECTED_PDF_SHA,
    "score" => row["score"],
    "decision" => row["decision"],
    "non_blocking_differences" => differences,
    "blocked" => nil
  }
end

def vf5_led_applicability!(chunk)
  raise "page fidelity" if ENV["RAG_LOCAL_PAGE_FIDELITY"] == "1"

  require "active_support/testing/time_helpers"
  page7 = vf5_led_meta(PAGE7_META, EXPECTED_PAGE7_META_SHA)
  page12 = vf5_led_meta(PAGE12_META, EXPECTED_PAGE12_META_SHA)
  capture = JSON.parse(Rails.root.join(TURN_CAPTURE).read)
  episode = capture.fetch("events").find { |event| event["kind"] == "episode_delta" }.fetch("episode_after")
  focus = capture.fetch("events").find { |event| event["kind"] == "document_focus" }.dig("after", 0, "source_uri")
  source = page7.fetch("original_source_uri")
  bucket = source.delete_prefix("s3://").split("/", 2).first
  raise "bucket #{KbDocument::KB_BUCKET}" unless KbDocument::KB_BUCKET == bucket
  raise "focus" unless focus == source
  raise "sibling uri" unless page12.fetch("original_source_uri") == source
  raise "sibling name" unless page12.fetch("canonical_name") == page7.fetch("canonical_name")
  raise "section" if page7.key?("section_identity") || page12.key?("section_identity")

  body = chunk.dup.force_encoding(Encoding::UTF_8)
  account = Account.find(capture.fetch("events").find { |event| event["kind"] == "episode_delta" }.fetch("account_id"))
  helper = Object.new
  helper.extend(ActiveSupport::Testing::TimeHelpers)
  report = nil
  helper.travel_to(Time.iso8601(episode.fetch("updated_at"))) do
    identity = Rag::EquipmentIdentity.from_episode(episode)
    raise "identity" unless identity&.known?

    selected = vf5_led_apply(body, page7, source, identity, account)
    sibling = vf5_led_apply("sibling body", page12, source, identity, account)
    report = {
      "label" => selected.labels.sole,
      "applicability" => selected.applicability.sole,
      "status" => selected.status.to_s,
      "body_unchanged" => selected.chunks.sole[:content] == body,
      "sibling_label" => sibling.labels.sole,
      "sibling_applicability" => sibling.applicability.sole,
      "sibling_body_unchanged" => sibling.chunks.sole[:content] == "sibling body",
      "known" => true,
      "facts" => identity.facts.map { |fact| [ fact["slot"], fact["value"] ] },
      "bucket" => bucket,
      "canonical_name" => page7.fetch("canonical_name"),
      "page_fidelity" => "off"
    }
  end
  unless report["applicability"] == "compatible" && report["label"] == "THIS JOB'S EQUIPMENT: VF5" &&
      report["body_unchanged"] && report["sibling_label"] == report["label"] &&
      report["sibling_applicability"] == "compatible" && report["sibling_body_unchanged"]
    raise "applicability #{report.inspect}"
  end

  report
end

def vf5_led_meta(path, sha)
  raw = Rails.root.join(path).binread
  raise "meta sha #{path}" unless Digest::SHA256.hexdigest(raw) == sha

  JSON.parse(raw).fetch("metadataAttributes")
end

def vf5_led_apply(content, metadata, focus, identity, account)
  chunk = {
    content: content,
    original_source_uri: metadata["original_source_uri"],
    location_uri: "s3://#{metadata['original_source_uri'].delete_prefix('s3://').split('/', 2).first}/bulk_chunks/1/#{metadata['document_id']}/chunk.txt",
    metadata: metadata
  }
  Rag::DocumentIdentityScope.apply([ chunk ], identity, focus_uris: [ focus ], viewer_account: account)
end

def vf5_led_prompt(base, label)
  text = base.dup.force_encoding(Encoding::UTF_8)
  seen = 0
  marked = text.gsub("<content>\n") { |match|
    seen += 1
    seen == 4 ? "<content>\n#{label}\n" : match
  }
  raise "result slots #{seen}" unless seen == 4

  marked
end

def vf5_led_without_mark(prompt, label)
  seen = 0
  prompt.gsub("<content>\n#{label}\n") { |match|
    seen += 1
    seen == 4 ? "<content>\n" : match
  }
end

def vf5_led_authorize!(base, chunk, prompt, provenance, label)
  text = base.dup.force_encoding(Encoding::UTF_8)
  body = chunk.dup.force_encoding(Encoding::UTF_8)
  raise "restore" unless vf5_led_without_mark(prompt, label) == text
  raise "marker" unless text.scan(MARKER).size == 1 && prompt.scan(MARKER).size == 1
  raise "open phrase" unless prompt.scan("and which remain open").size == 1 && text.scan("and which remain open").size == 1

  before = vf5_led_contents(text)
  after = vf5_led_contents(prompt)
  sources = prompt.to_enum(:scan, SectionPageContinuity::RESULT_PATTERN).map { Regexp.last_match[2] }
  raise "count" unless before.size == 4 && after.size == 4
  raise "results 1-3" unless before.first(3) == after.first(3)
  raise "content" unless after[3] == "#{label}\n#{body}"
  raise "result 4 base" unless before[3] == body
  raise "sources" unless sources == [ "1", "2", "3", "4" ]
  raise "goal" unless prompt[/^Goal: .*$/] == text[/^Goal: .*$/]
  raise "query" unless prompt[/^Query: .*$/] == text[/^Query: .*$/]
  raise "state" if prompt.include?("Reportado por el técnico:") && text.exclude?("Reportado por el técnico:")
  raise "orientation" if prompt.include?("Orientación según el manual") && text.exclude?("Orientación según el manual")
  raise "equipment line" unless label == "THIS JOB'S EQUIPMENT: VF5"
  raise "provenance" unless provenance["blocked"].nil?

  ceiling = Rag::LocalPassLedger.price(MODEL_ID, prompt.bytesize, 3000)
  provenance["character_ceiling_usd"] = format("%.6f", ceiling)
  provenance["prompt_bytes"] = prompt.bytesize
end

def vf5_led_flat(text)
  text.to_s.gsub(/\s+/, " ").strip
end

def vf5_led_contents(text)
  text.to_enum(:scan, SectionPageContinuity::RESULT_PATTERN).map { Regexp.last_match[1] }
end

def vf5_led_balance
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

def vf5_led_write!(root, base, chunk, prompt, pages, provenance, balance, live)
  root.join("prompt-before.txt").binwrite(base)
  root.join("prompt-after.txt").binwrite(prompt)
  root.join("source-chunk.txt").binwrite(chunk)
  root.join("page-7.txt").write(pages.fetch("layout"))
  root.join("page-7-raw.txt").write(pages.fetch("raw"))
  png, png_status = Open3.capture2("pdftoppm", "-f", "7", "-l", "7", "-png", "-r", "140", "-singlefile", Rails.root.join(PDF_PATH).to_s, root.join("page-7").to_s)
  raise "pdftoppm #{png_status.exitstatus} #{png}" unless png_status.success? && root.join("page-7.png").file?

  vf5_led_diff(root.join("prompt-before.txt"), root.join("prompt-after.txt"), root.join("diff-prompt.diff"))
  root.join("provenance.json").write(JSON.pretty_generate(provenance))
  root.join("rubric.json").write(JSON.pretty_generate(RUBRIC))
  root.join("balance_before.json").write(JSON.generate(balance))
  body = Rag::CapturedGenerationReplay.invoke_body_json(prompt: prompt.dup.force_encoding(Encoding::UTF_8), max_tokens: 3000, temperature: 0.1, system: nil)
  parsed = JSON.parse(body)
  raise "system" if parsed.key?("system")
  raise "temperature" unless parsed["temperature"] == 0.1
  raise "max_tokens" unless parsed["max_tokens"] == 3000
  raise "version" unless parsed["anthropic_version"] == Rag::CapturedGenerationReplay::ANTHROPIC_VERSION
  raise "messages" unless parsed["messages"] == [ { "role" => "user", "content" => prompt.dup.force_encoding(Encoding::UTF_8) } ]

  root.join("body-after.json").write(body)
  root.join("manifest.json").write(JSON.pretty_generate(vf5_led_manifest(prompt, body, provenance, balance, live)))
  body
end

def vf5_led_diff(left, right, path)
  output, status = Open3.capture2("diff", "-u", left.to_s, right.to_s)
  raise "diff" unless status.success? || status.exitstatus == 1

  path.write(output)
end

def vf5_led_manifest(prompt, body, provenance, balance, live)
  {
    "live" => live,
    "head" => `git rev-parse HEAD`.strip,
    "base_path" => BASE_PATH,
    "chunk_path" => CHUNK_PATH,
    "pdf_sha256" => EXPECTED_PDF_SHA,
    "base_prompt_sha256" => EXPECTED_BASE_SHA,
    "chunk_sha256" => EXPECTED_CHUNK_SHA,
    "prompt_sha256" => Digest::SHA256.hexdigest(prompt),
    "body_sha256" => Digest::SHA256.hexdigest(body),
    "rubric_sha256" => Digest::SHA256.hexdigest(JSON.generate(RUBRIC)),
    "model_id" => MODEL_ID,
    "temperature" => 0.1,
    "max_tokens" => 3000,
    "system" => "absent",
    "anthropic_version" => Rag::CapturedGenerationReplay::ANTHROPIC_VERSION,
    "samples" => 3,
    "attempt_limit" => 1,
    "retry_policy" => "CapturedGenerationReplay.run_sample with attempt_limit 1. A transient error may call it again while attempts and calculated spend remain inside this job. Wait comes from TransientBackoff. SDK max_attempts stays 1.",
    "budget_note" => "US$0.16 limits additional calculated spend plus unknown plus open holds, plus the full reserve of the next call, before each attempt. That reserve is LocalPassLedger.price of the prompt byte size and 3000 output tokens, the hold AssignmentSpend opens. The previous call's settled cost is not the admission estimate. The cumulative caps stay 96 attempts and US$4. Fifteen attempts stay reserved. The process ledger dollar cap is the remaining global budget so the hold can be admitted. The process call cap is 3.",
    "sdk_max_attempts" => 1,
    "character_ceiling_usd" => provenance["character_ceiling_usd"],
    "job_calls" => JOB_CALLS,
    "job_usd" => JOB_USD.to_s("F"),
    "reserve_calls" => RESERVE_CALLS,
    "balance_before" => balance,
    "selection" => "Result 4 keeps the captured chunk byte for byte and gains the applicability line DocumentIdentityScope returned for that chunk. Source number 4 stays only in the wrapper. Results 1-3 and the rest of the prompt stay byte for byte. No Retrieve.",
    "provenance" => provenance.except("character_ceiling_usd", "prompt_bytes")
  }
end

def vf5_led_refuse_budget!(balance, reserve)
  remaining_calls = CALL_CAP - balance["attempts"]
  remaining_usd = COST_CAP - BigDecimal(balance["committed_usd"]) - BigDecimal(balance["unknown_usd"]) - BigDecimal(balance["held_usd"])
  raise "reserve calls" if remaining_calls < RESERVE_CALLS + JOB_CALLS
  raise "global cost" if remaining_usd < JOB_USD

  decision = vf5_led_admit(vf5_led_opening_snapshot(balance), balance, reserve)
  raise "opening admission #{decision.inspect}" unless decision["admitted"]

  decision
end

def vf5_led_opening_snapshot(balance)
  {
    "attempts" => balance["attempts"],
    "committed_usd" => balance["committed_usd"],
    "unknown_usd" => balance["unknown_usd"],
    "held_usd" => balance["held_usd"]
  }
end

def vf5_led_admit(snapshot, opening, reserve)
  used = snapshot["attempts"].to_i - opening["attempts"].to_i
  committed = BigDecimal(snapshot["committed_usd"].to_s)
  unknown = BigDecimal(snapshot.fetch("unknown_usd", "0").to_s)
  held = BigDecimal(snapshot.fetch("held_usd", "0").to_s)
  additional = committed + unknown + held -
    BigDecimal(opening["committed_usd"].to_s) -
    BigDecimal(opening.fetch("unknown_usd", "0").to_s) -
    BigDecimal(opening.fetch("held_usd", "0").to_s)
  ceiling = BigDecimal(reserve.to_s)
  job_total = additional + ceiling
  global_total = committed + unknown + held + ceiling
  reasons = []
  reasons << "attempts" unless used < JOB_CALLS && snapshot["attempts"].to_i < CALL_CAP - RESERVE_CALLS
  reasons << "job_usd" unless job_total <= JOB_USD
  reasons << "global_usd" unless global_total <= COST_CAP
  {
    "admitted" => reasons.empty?,
    "reasons" => reasons,
    "used" => used,
    "additional_usd" => format("%.6f", additional),
    "reserve_usd" => format("%.6f", ceiling),
    "reserve_basis" => "prompt bytes as input tokens plus 3000 output tokens",
    "job_total_usd" => format("%.6f", job_total),
    "job_limit_usd" => format("%.6f", JOB_USD),
    "global_total_usd" => format("%.6f", global_total),
    "global_limit_usd" => format("%.6f", COST_CAP),
    "attempts" => snapshot["attempts"].to_i,
    "attempt_ceiling" => CALL_CAP - RESERVE_CALLS
  }
end

def vf5_led_match_preview!(prompt)
  manifest = Rails.root.join("tmp/field_companion/vf5_section56/preview-applicability/manifest.json")
  return unless manifest.file?

  preview = JSON.parse(manifest.read)
  raise "preview drift" unless preview["prompt_sha256"] == Digest::SHA256.hexdigest(prompt)
  raise "preview rubric" unless preview["rubric_sha256"] == Digest::SHA256.hexdigest(JSON.generate(RUBRIC))
end

def vf5_led_execute(root, run_id, prompt, balance)
  stored = root.join("prompt-after.txt").binread
  stored_body = root.join("body-after.json").read
  raise "stored prompt" unless Digest::SHA256.hexdigest(stored) == Digest::SHA256.hexdigest(prompt)
  raise "stored body" unless JSON.parse(stored_body).dig("messages", 0, "content") == prompt.dup.force_encoding(Encoding::UTF_8)

  results = []
  ENV.delete("RAG_ASSIGNMENT_SPEND_PATH")
  spend = Rag::AssignmentSpend.new(path: Rails.root.join(SPEND_PATH), call_cap: CALL_CAP, cost_cap_usd: COST_CAP)
  ENV["RAG_LOCAL_PASS_GUARD"] = "1"
  ENV["RAG_LOCAL_PASS_CALL_CAP"] = JOB_CALLS.to_s
  ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = format("%.6f", COST_CAP - BigDecimal(balance["committed_usd"]) - BigDecimal(balance["unknown_usd"]))
  ENV["AWS_MAX_ATTEMPTS"] = "1"
  Rag::LocalPassLedger.reset!
  Rag::LocalPassLedger.reset_local_process!
  raise "ledger #{Rag::LocalPassLedger.missing_requirements.join(' ')}" unless Rag::LocalPassLedger.armed?

  client = vf5_benchmark_client
  max_attempts = client.instance_variable_get(:@client).config.max_attempts
  raise "max_attempts #{max_attempts}" unless max_attempts == 1

  prepared = vf5_led_prepared(prompt)
  root.join("prepared.json").write(JSON.generate("prompt_sha256" => prepared.prompt_sha256, "body_sha256" => prepared.body_sha256, "at" => Time.now.utc.iso8601))
  3.times do |index|
    name = "s#{index + 1}"
    directory = root.join(name)
    directory.mkpath
    sample = vf5_led_one_sample(name, directory, prepared, client, spend, balance, run_id, results)
    break unless sample && sample.status == "returned"
  end
  results.count { |row| row["status"] == "returned" } == 3 ? 0 : 2
rescue Rag::AssignmentSpend::Stop, Rag::LocalPassLedger::Stop => error
  results << { "status" => "stopped", "reason" => error.message }
  2
ensure
  if defined?(results) && results && root
    final_balance = vf5_led_balance_now
    root.join("balance_after.json").write(JSON.generate(final_balance))
    root.join("results.json").write(JSON.generate("results" => results, "balance_after" => final_balance))
  end
end

def vf5_led_one_sample(name, directory, prepared, client, spend, opening, run_id, results)
  sample = nil
  attempt = 0
  loop do
    reserve = Rag::LocalPassLedger.price(MODEL_ID, prepared.prompt.bytesize, prepared.max_tokens)
    decision = vf5_led_admit(spend.snapshot, opening, reserve)
    decision["prompt_bytes"] = prepared.prompt.bytesize
    decision["max_tokens"] = prepared.max_tokens
    decision["sample"] = name
    next_attempt = attempt + 1
    attempt_dir = directory.join(format("a%d", next_attempt))
    attempt_dir.mkpath
    attempt_dir.join("admission.json").write(JSON.generate(decision))
    unless decision["admitted"]
      results << { "sample" => name, "status" => "not_started", "reason" => "cap", "attempts_already" => attempt, "admission" => decision }
      return nil
    end
    attempt = next_attempt
    attempt_dir.join("checkpoint.json").write(JSON.generate(
      "sample" => name,
      "attempt" => attempt,
      "prompt_sha256" => prepared.prompt_sha256,
      "body_sha256" => prepared.body_sha256,
      "model_id" => MODEL_ID,
      "temperature" => prepared.temperature,
      "max_tokens" => prepared.max_tokens,
      "system" => nil
    ))
    sample = Rag::CapturedGenerationReplay.run_sample(
      prepared: prepared,
      model_id: MODEL_ID,
      client: client,
      spend: spend,
      output_dir: attempt_dir,
      run_id: run_id,
      correlation_prefix: "vf5-section56:#{name}",
      attempt_limit: 1
    )
    raise "prompt drifted" unless sample.prompt_sha256 == prepared.prompt_sha256
    raise "body drifted" unless sample.body_sha256 == prepared.body_sha256

    row = vf5_led_sample(name, sample, attempt)
    results << row
    return sample if sample.status == "returned"
    return sample unless Rag::CapturedGenerationReplay.error_kind(sample.error_class) == "transient"

    wait = Rag::TransientBackoff.wait_seconds(attempt - 1)
    row["wait_seconds"] = wait
    sleep wait
  end
end

def vf5_led_prepared(prompt)
  replay = Rag::CapturedGenerationReplay
  text = prompt.dup.force_encoding(Encoding::UTF_8)
  body = replay.invoke_body_json(prompt: text, max_tokens: 3000, temperature: 0.1, system: nil)
  replay::Prepared.new(
    turn: 1,
    request_id: REQUEST_ID,
    prompt: text,
    prompt_sha256: Digest::SHA256.hexdigest(text),
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

def vf5_led_sample(name, sample, attempt)
  {
    "sample" => name,
    "attempt" => attempt,
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

def vf5_led_balance_now
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

unless ENV["VF5_SECTION56_LED_REQUIRE"] == "1"
  code = vf5_led_main
  exit code unless code.zero?
end
