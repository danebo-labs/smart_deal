# frozen_string_literal: true

# Fase 3 — Reingesta byte-fiel del corpus benchmark (cohorte v2): manual PDF +
# imagen PNG en UNA pasada por el path real de ingesta, entrando en el borde
# del job (UploadAndSyncAttachmentsJob → QueryOrchestratorService →
# CustomChunkingPipeline). Se salta unicamente el transporte del navegador,
# que re-encodea imagenes a JPEG (canvas 1024px) y romperia el SHA del manifest.
#
# Hace:
#   1. Verifica SHA-256 local de ambos archivos contra el manifest del corpus.
#   2. Verifica que la fecha actual coincide con la fecha embebida en los keys.
#   3. Ejecuta la ingesta real (paga: ~1 llamada Sonnet por pagina + 1 por foto).
#   4. Verifica SHA-256 de ambos objetos en S3 contra el manifest.
#   5. Espera el ingestion job de Bedrock KB hasta COMPLETE.
#   6. Limpia pins/historial de la sesion benchmark y pinnea ambos documentos.
#
# Uso:
#   RAG_INGEST_CONFIRM=1 bin/rails runner script/ingest_benchmark_corpus.rb
#
# Opcional:
#   RAG_BENCHMARK_CORPUS_DIR=/ruta/a/corpus_v2_subir
#   RAG_BENCHMARK_SESSION=mvp-shared

require "digest"
require "base64"

abort("Set RAG_INGEST_CONFIRM=1 to run (performs paid Anthropic calls)") unless ENV["RAG_INGEST_CONFIRM"] == "1"

manifest = JSON.parse(File.read("script/fixtures/rag_quality_benchmark_corpus.json"))
objects  = manifest.fetch("objects")
corpus_dir = ENV.fetch("RAG_BENCHMARK_CORPUS_DIR", File.expand_path("~/Desktop/corpus_v2_subir"))

sources = objects.transform_values do |expected|
  key      = expected.fetch("s3_key")
  filename = File.basename(key)
  path     = File.join(corpus_dir, filename)
  abort("Missing local file: #{path}") unless File.exist?(path)

  binary = File.binread(path)
  sha    = Digest::SHA256.hexdigest(binary)
  abort("#{filename}: local SHA #{sha} != manifest #{expected['sha256']}") unless sha == expected.fetch("sha256")

  key_date = key[%r{uploads/(\d{4}-\d{2}-\d{2})/}, 1]
  unless Date.current.iso8601 == key_date
    abort("#{filename}: manifest key date #{key_date} != today #{Date.current.iso8601}; re-version the manifest first")
  end

  { key: key, filename: filename, binary: binary, sha256: sha }
end

manual = sources.fetch("manual")
image  = sources.fetch("image")

# Mismo tratamiento server-side que el controller para la imagen: <=3.75 MB se
# salta la compresion (bytes intactos) y genera solo el thumbnail para la UI.
compressed = ImageCompressionService.compress_with_thumbnail(
  Base64.strict_encode64(image[:binary]), "image/png"
)
raise "Image compression did not skip; bytes would change" unless compressed[:binary] == image[:binary]

image_payload = {
  data:                   compressed[:data],
  media_type:             compressed[:media_type],
  filename:               image[:filename],
  thumbnail_binary:       compressed[:thumbnail_binary],
  thumbnail_content_type: compressed[:thumbnail_content_type],
  thumbnail_width:        compressed[:thumbnail_width],
  thumbnail_height:       compressed[:thumbnail_height]
}.compact

document_payload = {
  data:       Base64.strict_encode64(manual[:binary]),
  media_type: "application/pdf",
  filename:   manual[:filename]
}

session = ConversationSession.find_by(identifier: ENV.fetch("RAG_BENCHMARK_SESSION", "mvp-shared"))

puts "Ingesting #{manual[:filename]} (#{manual[:binary].bytesize} bytes) + #{image[:filename]} (#{image[:binary].bytesize} bytes)…"
started_at = Time.current
UploadAndSyncAttachmentsJob.perform_now(
  images_payload:    [ image_payload ],
  documents_payload: [ document_payload ],
  conv_session_id:   session&.id,
  locale:            "es"
)
puts format("Parse + upload finished in %.1fs", Time.current - started_at)

# ── Verificacion S3 byte-fiel ─────────────────────────────────────────────────
bucket = KbDocument::KB_BUCKET
s3 = Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
failures = []

sources.each do |name, src|
  remote_sha = Digest::SHA256.hexdigest(s3.get_object(bucket: bucket, key: src[:key]).body.read)
  status = remote_sha == src[:sha256] ? "OK" : "MISMATCH"
  puts "#{name}: s3://#{bucket}/#{src[:key]} SHA #{remote_sha[0, 16]}… [#{status}]"
  failures << name unless status == "OK"

  prefix = "bulk_chunks/#{Date.current.iso8601}/#{src[:sha256]}/"
  chunk_count = s3.list_objects_v2(bucket: bucket, prefix: prefix).contents.count { |o| o.key.end_with?(".txt") }
  puts "#{name}: #{chunk_count} chunk(s) under #{prefix}"
  failures << "#{name} (no chunks)" if chunk_count.zero?
end

docs = KbDocument.where(s3_key: sources.values.pluck(:key))
puts "KbDocument rows: #{docs.count}/2"
failures << "KbDocument rows != 2" unless docs.count == 2

abort("FAILURES: #{failures.join(', ')}") if failures.any?

# ── Espera del ingestion job de Bedrock KB ────────────────────────────────────
kb_id = ENV["BEDROCK_KNOWLEDGE_BASE_ID"].presence ||
        Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
ds_id = ENV["BEDROCK_BULK_DATA_SOURCE_ID"].presence ||
        Rails.application.credentials.dig(:bedrock, :bulk_data_source_id)
agent = Aws::BedrockAgent::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))

job = agent.list_ingestion_jobs(
  knowledge_base_id: kb_id, data_source_id: ds_id, max_results: 50
).ingestion_job_summaries.max_by(&:started_at)
abort("No ingestion job found for KB #{kb_id} / DS #{ds_id}") unless job

print "KB ingestion job #{job.ingestion_job_id}: "
status = job.status
40.times do
  break unless %w[STARTING IN_PROGRESS].include?(status)

  sleep 15
  status = agent.get_ingestion_job(
    knowledge_base_id: kb_id, data_source_id: ds_id, ingestion_job_id: job.ingestion_job_id
  ).ingestion_job.status
  print "#{status} "
end
puts
abort("KB ingestion job ended #{status}") unless status == "COMPLETE"

# ── Pins limpios (Fase 3 paso 11) ────────────────────────────────────────────
if session
  session.update!(active_entities: {}, conversation_history: [])
  docs.each { |doc| session.pin_kb_document!(doc) or abort("Could not pin #{doc.s3_key}") }
  session.reload
  puts "Session #{session.identifier}: pins=#{session.active_entities.size} history=#{session.conversation_history.size}"
else
  puts "WARN: benchmark session not found — pins not set"
end

puts "RESULT: OK — corpus v2 ingested, indexed COMPLETE, pinned"
