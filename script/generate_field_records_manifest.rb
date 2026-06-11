# frozen_string_literal: true

# Fase 4 — Genera script/fixtures/rag_quality_benchmark_field_records.json a
# partir de los renderers deterministas ejecutados contra el indice REAL, y
# mapea las 24 unidades funcionales del gate contra los RECORD_ID rendidos.
#
# El mapeo por regex es CORPUS-ESPECIFICO y vive solo en el fixture/benchmark
# (nunca en codigo de produccion). El fixture resultante debe revisarse contra
# el PDF fuente antes de congelarse (la revision de §2.4 paginas 8-11 está
# documentada en docs/RAG_100_PERCENT_FIDELITY_PLAN_2026-06-10.md).
#
# Uso: bin/rails runner script/generate_field_records_manifest.rb

require "json"
require "digest"

UNIT_PATTERNS = {
  "ground-diagnostic-led"            => { type: "FUNCTIONAL_TEST", action: /LED|diagnóstico/i, source: /2\.4\.1|continuación/i, result: /LED/i },
  "ground-emergency-off"             => { type: "FUNCTIONAL_TEST", action: /a tierra a la posición .?APAGADO/i },
  "ground-key-platform-blocks-lift"  => { type: "FUNCTIONAL_TEST", action: /llave.*(?:plataforma|apagado)/i, result: /no sube/i },
  "ground-key-ground-allows-lift"    => { type: "FUNCTIONAL_TEST", action: /control desde el suelo/i, result: /elevarse/i },
  "ground-first-descent"             => { type: "FUNCTIONAL_TEST", action: /\ABajar y mantener presionado el interruptor de elevación de la plataforma\.?\z/i, result: /2 m/ },
  "ground-second-descent"            => { type: "FUNCTIONAL_TEST", action: /nuevamente/i, result: /posición más baja/i },
  "platform-emergency-off"           => { type: "FUNCTIONAL_TEST", action: /Presion\w* el botón rojo de parada de emergencia de la plataforma/i, result: /No se ejecutarán/i },
  "platform-emergency-on-led"        => { type: "FUNCTIONAL_TEST", action: /Tir\w* del botón rojo de parada de emergencia a la posición .?ON/i, result: /LED de diagnóstico se iluminará/i },
  "platform-horn"                    => { type: "FUNCTIONAL_TEST", action: /botón de la bocina/i, result: /Sonará la bocina/i },
  "platform-no-enable-blocks-motion" => { type: "FUNCTIONAL_TEST", action: /[Ss]in presionar el botón de inicio/i, result: /No se ejecutarán/i },
  "platform-lift-and-pit-deploy"     => { type: "FUNCTIONAL_TEST", action: /flecha azul/i, result: /elevarse.*fosos|fosos.*desplegado/im },
  "platform-release-stops-lift"      => { type: "FUNCTIONAL_TEST", action: /S(?:uelte|olt\w*) la palanca/i, result: /dejar de subir/i },
  "platform-descent-alarm"           => { type: "FUNCTIONAL_TEST", action: /flecha amarilla/i, result: /alarma de caída/i },
  "steering-left"                    => { type: "FUNCTIONAL_TEST", result: /volante.*flecha izquierda/i },
  "steering-right"                   => { type: "FUNCTIONAL_TEST", result: /volante.*derecha/i },
  "drive-brake-forward"              => { type: "FUNCTIONAL_TEST", action: /flecha hacia arriba/i, result: /flecha hacia arriba.*(?:detiene|detenerse)/i },
  "drive-brake-reverse"              => { type: "FUNCTIONAL_TEST", action: /flecha hacia abajo/i, result: /flecha hacia abajo.*deten/i },
  "limited-speed-setup-pit-deploy"   => { type: "FUNCTIONAL_TEST", source: /velocidad de conducción limitada/i, result: /desplegado/i },
  "limited-speed-20cm"               => { type: "FUNCTIONAL_TEST", result: /20 cm\/s/i },
  "tilt-sensor-stop-alarm"           => { type: "FUNCTIONAL_TEST", source: /sensor de inclinación/i, result: /150/i },
  "pit-deploy-at-2m"                 => { type: "FUNCTIONAL_TEST", source: /pozos/i, result: /2 m.*desplegado|desplegado.*2 m/im },
  "pit-pressure-immobility"          => { type: "FUNCTIONAL_TEST", source: /pozos/i, result: /no se moverá/i },
  "pit-storage-return"               => { type: "FUNCTIONAL_TEST", source: /pozos/i, result: /posición de almacenamiento/i },
  "pit-obstacle-blocks-traction"     => { type: "FUNCTIONAL_TEST", source: /pozos/i, result: /tracci[oó]n no se puede/i }
}.freeze

# Guardas del gap historico #2: estos records deben quedar SIEMPRE como
# precaucion, jamas en la seccion obligatoria.
PRECAUTION_SENTINELS = {
  "dizziness-stays-precaution"    => /mareos/i,
  "unauthorized-stays-precaution" => /personal no interfiera|personas no autorizadas/i
}.freeze

uris_all   = KbDocument.order(:id).map { |d| d.display_s3_uri(KbDocument::KB_BUCKET) }
manual_uri = uris_all.find { |u| u.end_with?(".pdf") }
corpus     = JSON.parse(File.read("script/fixtures/rag_quality_benchmark_corpus.json"))

def renderer_for(question, uris, sources)
  Rag::DeterministicRenderer.build(
    question: question, entity_s3_uris: uris, entity_sources: sources,
    force_entity_filter: true, response_locale: "es"
  ) or abort("intent did not match: #{question}")
end

def records_for(renderer)
  retrieval = renderer.instance_variable_get(:@rag_service).retrieve_chunks(
    renderer.instance_variable_get(:@question),
    entity_s3_uris: renderer.instance_variable_get(:@entity_s3_uris),
    entity_sources: renderer.instance_variable_get(:@entity_sources),
    force_entity_filter: true,
    number_of_results: Rag::DeterministicRenderer::FULL_SCOPE_CANDIDATES
  )
  ledger = Rag::FieldRecordParser.parse_chunks(retrieval[:chunks])
  [ renderer.send(:select_records, ledger), ledger ]
end

ft = renderer_for("¿Qué pruebas funcionales previas al uso indica el manual y qué resultado esperado tiene cada una?", [ manual_uri ], [ "document" ])
sw = renderer_for("Antes de operar este equipo, ¿qué comprobaciones debo realizar y en qué condiciones debo detener el trabajo?", uris_all, [ "document", "image_upload" ])

ft_records, = records_for(ft)
sw_records, = records_for(sw)
mandatory   = sw_records.select(&:stop_work?)
precautions = sw_records.reject(&:stop_work?)

units = {}
problems = []
UNIT_PATTERNS.each do |unit_id, spec|
  matches = ft_records.select do |r|
    r.type == spec[:type] &&
      (!spec[:action] || r.action.match?(spec[:action])) &&
      (!spec[:result] || r.expected_result.match?(spec[:result])) &&
      (!spec[:source] || r.source.match?(spec[:source]))
  end
  problems << "unit #{unit_id}: #{matches.size} matches" if matches.empty?
  units[unit_id] = {
    "record_ids" => matches.map(&:record_id),
    "verdict"    => "supported (PDF §2.4 pp.8-11 review 2026-06-10)"
  }
end

sentinels = {}
PRECAUTION_SENTINELS.each do |sentinel_id, pattern|
  matched = precautions.select { |r| r.action.match?(pattern) }
  problems << "sentinel #{sentinel_id}: not found among precautions" if matched.empty?
  promoted = mandatory.select { |r| r.stop_trigger.to_s.match?(pattern) }
  problems << "sentinel #{sentinel_id}: PROMOTED to mandatory!" if promoted.any?
  sentinels[sentinel_id] = matched.map(&:record_id)
end

abort("MANIFEST PROBLEMS:\n#{problems.join("\n")}") if problems.any?

record_payload = lambda do |r|
  {
    "record_id" => r.record_id, "type" => r.type, "source" => r.source,
    "action" => r.action, "expected_result" => r.expected_result,
    "stop_trigger" => r.stop_trigger, "stop_action" => r.stop_action,
    "evidence" => r.evidence,
    "chunk_sha256s" => r.provenances.pluck(:chunk_sha256).uniq,
    "uris" => r.provenances.pluck(:uri).uniq
  }.compact
end

manifest = {
  "version" => "2026-06-10-v2-field-records-v1",
  "corpus" => corpus["objects"],
  "ingestion_contract_version" => BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
  "ingestion_prompt_fingerprint_sha256" => BatchChunkingPrompt.prompt_fingerprint_sha256,
  "functional_test_cases" => {
    "case_keys" => [ "isolated:5", "conversation:5" ],
    "expected_record_ids" => ft_records.map(&:record_id).sort,
    "records" => ft_records.map(&record_payload)
  },
  "stop_work_cases" => {
    "case_keys" => [ "isolated:3", "conversation:3" ],
    "expected_mandatory_record_ids" => mandatory.map(&:record_id).sort,
    "expected_record_ids" => sw_records.map(&:record_id).sort,
    "mandatory_records" => mandatory.map(&record_payload),
    "precaution_sentinels" => sentinels
  },
  "functional_units" => units,
  "review" => {
    "method" => "records compared against source PDF pages 8-11 (§2.4 complete) and pages 3/9/10/18 readings",
    "reviewer" => "claude-fable-5 + operator sign-off pending",
    "date" => "2026-06-10"
  }
}

path = "script/fixtures/rag_quality_benchmark_field_records.json"
File.write(path, JSON.pretty_generate(manifest))
puts "FT records: #{ft_records.size}  units mapped: #{units.size}  mandatory: #{mandatory.size}  precautions: #{precautions.size}"
units.each { |id, u| puts format("  %-34s %s", id, u['record_ids'].join(',')) }
puts "Wrote #{path} (sha256 #{Digest::SHA256.hexdigest(File.read(path))[0, 16]}…)"
