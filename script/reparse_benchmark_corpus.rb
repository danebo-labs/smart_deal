# frozen_string_literal: true

# Re-parsea el corpus benchmark v2 bajo el contrato de ingesta vigente SIN
# tocar los objetos originales en S3 (que ya estan byte-verificados en sus
# claves canonicas). Usa la capa de servicio real (SingleFileChunkingService,
# el mismo punto que CustomChunkingPipeline invoca tras subir el original):
#
#   1. Verifica SHA local de ambos archivos contra el manifest del corpus.
#   2. Verifica que los objetos S3 canonicos siguen byte-identicos.
#   3. Borra TODOS los chunks previos (bulk_chunks/) del bucket dev.
#   4. Re-parsea manual e imagen (pagado: ~1 llamada por pagina + 1 por foto).
#   5. Lanza el sync de KB y espera COMPLETE.
#   6. Verifica sidecars con el contrato vigente.
#
# Uso:
#   RAG_INGEST_CONFIRM=1 bin/rails runner script/reparse_benchmark_corpus.rb

require "digest"

abort("Set RAG_INGEST_CONFIRM=1 to run (performs paid Anthropic calls)") unless ENV["RAG_INGEST_CONFIRM"] == "1"

# Telemetria de costo inline (sin worker): los TrackIngestionUsageJob quedan
# registrados en BedrockQuery/CostMetric para el analisis de costos del plan.
ActiveJob::Base.queue_adapter = :inline

manifest   = JSON.parse(File.read("script/fixtures/rag_quality_benchmark_corpus.json"))
corpus_dir = ENV.fetch("RAG_BENCHMARK_CORPUS_DIR", File.expand_path("~/Desktop/corpus_v2_subir"))
bucket     = KbDocument::KB_BUCKET
s3         = Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))

sources = manifest.fetch("objects").transform_values do |expected|
  key      = expected.fetch("s3_key")
  filename = File.basename(key)
  path     = File.join(corpus_dir, filename)
  binary   = File.binread(path)
  sha      = Digest::SHA256.hexdigest(binary)
  abort("#{filename}: local SHA != manifest") unless sha == expected.fetch("sha256")

  remote_sha = Digest::SHA256.hexdigest(s3.get_object(bucket: bucket, key: key).body.read)
  abort("#{filename}: S3 object SHA != manifest") unless remote_sha == sha

  { key: key, filename: filename, binary: binary, sha256: sha }
end

# Limpieza de chunks previos (cualquier fecha/contrato).
old_keys = []
s3.list_objects_v2(bucket: bucket, prefix: "bulk_chunks/").each do |page|
  old_keys.concat(page.contents.map(&:key))
end
old_keys.each_slice(1000) do |slice|
  s3.delete_objects(bucket: bucket, delete: { objects: slice.map { |k| { key: k } } })
end
puts "Deleted #{old_keys.size} previous chunk object(s)"

content_types = { "manual" => "application/pdf", "image" => "image/png" }
sources.each do |name, src|
  puts "Re-parsing #{src[:filename]}…"
  asset = SingleFileChunkingService.new(
    binary:       src[:binary],
    content_type: content_types.fetch(name),
    filename:     src[:filename],
    s3_key:       src[:key],
    sha256:       src[:sha256],
    locale:       "es"
  ).call
  puts "  chunks=#{asset.chunks_count} prefix=#{asset.chunks_s3_prefix} degraded=#{Array(asset.degraded_pages).inspect}"
  abort("#{name}: degraded pages #{asset.degraded_pages.inspect}") if Array(asset.degraded_pages).any?

  sidecar = JSON.parse(
    s3.get_object(bucket: bucket, key: "#{asset.chunks_s3_prefix}/chunk_0.txt.metadata.json").body.read
  ).fetch("metadataAttributes")
  expected_contract = name == "image" ? FieldPhotoPrompt::INGESTION_CONTRACT_VERSION : BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
  abort("#{name}: sidecar contract #{sidecar['ingestion_contract_version']}") unless sidecar["ingestion_contract_version"] == expected_contract
  abort("#{name}: sidecar original_source_uri mismatch") unless sidecar["original_source_uri"] == "s3://#{bucket}/#{src[:key]}"
end

result = BulkKbSyncService.new.sync!(uploaded_filenames: sources.values.pluck(:filename), locale: "es")
abort("KB sync did not start") unless result

agent = Aws::BedrockAgent::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
status = "STARTING"
print "KB ingestion job #{result[:job_id]}: "
60.times do
  status = agent.get_ingestion_job(
    knowledge_base_id: result[:kb_id], data_source_id: result[:data_source_id],
    ingestion_job_id: result[:job_id]
  ).ingestion_job.status
  print "#{status} "
  break unless %w[STARTING IN_PROGRESS].include?(status)

  sleep 15
end
puts
abort("KB ingestion job ended #{status}") unless status == "COMPLETE"
puts "RESULT: OK — corpus re-parsed under #{BatchChunkingPrompt::INGESTION_CONTRACT_VERSION} / #{FieldPhotoPrompt::INGESTION_CONTRACT_VERSION} and indexed"
