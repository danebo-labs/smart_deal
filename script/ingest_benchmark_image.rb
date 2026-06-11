# frozen_string_literal: true

# Ingesta byte-fiel de la imagen del corpus benchmark (cohorte v2).
#
# Por que no el chat web: rag_chat_controller.js re-encodea TODA imagen a JPEG
# (canvas, max 1024 px, q=0.82) antes del POST, asi que los bytes en S3 nunca
# coincidirian con el SHA congelado del manifest y ademas dependerian del
# navegador (no reproducible). Este script entra al path REAL de ingesta en el
# borde del job (UploadAndSyncAttachmentsJob -> QueryOrchestratorService ->
# CustomChunkingPipeline), saltando unicamente el transporte/compresion del
# navegador. La compresion server-side (ImageCompressionService) se salta sola
# para binarios <= 3.75 MB, asi que los bytes del PNG llegan intactos a S3;
# el thumbnail UI se genera igual, sin alterar el original.
#
# COSTO: una llamada Anthropic (FieldPhotoPrompt, Sonnet) + sync KB Bedrock.
# Requiere creditos Anthropic y credenciales AWS dev.
#
# Uso:
#   RAG_INGEST_CONFIRM=1 bin/rails runner script/ingest_benchmark_image.rb
#
# Opcional:
#   RAG_BENCHMARK_IMAGE_PATH=/ruta/al/pagina_16_esquema_hidraulico.png

require "digest"
require "base64"

manifest = JSON.parse(File.read("script/fixtures/rag_quality_benchmark_corpus.json"))
expected = manifest.fetch("objects").fetch("image")
expected_key = expected.fetch("s3_key")
expected_sha = expected.fetch("sha256")
filename = File.basename(expected_key)

abort("Set RAG_INGEST_CONFIRM=1 to run (performs a paid Anthropic call)") unless ENV["RAG_INGEST_CONFIRM"] == "1"

path = ENV.fetch(
  "RAG_BENCHMARK_IMAGE_PATH",
  File.expand_path("~/Desktop/corpus_v2_subir/#{filename}")
)
abort("Image not found: #{path}") unless File.exist?(path)

binary = File.binread(path)
local_sha = Digest::SHA256.hexdigest(binary)
abort("Local SHA #{local_sha} != manifest #{expected_sha}") unless local_sha == expected_sha

# El key S3 embebe la fecha de subida (uploads/<Date.current>/<filename>).
key_date = expected_key[%r{uploads/(\d{4}-\d{2}-\d{2})/}, 1]
unless Date.current.iso8601 == key_date
  abort("Manifest key date #{key_date} != today #{Date.current.iso8601}; re-version the corpus manifest first")
end

if KbDocument.exists?(s3_key: expected_key)
  abort("KbDocument already exists for #{expected_key}; clean up before re-ingesting")
end

# Mismo tratamiento server-side que el controller: <=3.75 MB se salta la
# compresion (bytes intactos) y se genera solo el thumbnail para la UI.
compressed = ImageCompressionService.compress_with_thumbnail(Base64.strict_encode64(binary), "image/png")
raise "Compression did not skip; bytes would change" unless compressed[:binary] == binary

session = ConversationSession.find_by(identifier: ENV.fetch("RAG_BENCHMARK_SESSION", "mvp-shared"))

payload = {
  data:                   compressed[:data],
  media_type:             compressed[:media_type],
  filename:               filename,
  thumbnail_binary:       compressed[:thumbnail_binary],
  thumbnail_content_type: compressed[:thumbnail_content_type],
  thumbnail_width:        compressed[:thumbnail_width],
  thumbnail_height:       compressed[:thumbnail_height]
}.compact

puts "Ingesting #{filename} (#{binary.bytesize} bytes, sha #{local_sha[0, 12]}…) via UploadAndSyncAttachmentsJob…"
UploadAndSyncAttachmentsJob.perform_now(
  images_payload:    [ payload ],
  documents_payload: [],
  conv_session_id:   session&.id,
  locale:            "es"
)

# Verificacion post-ingesta: bytes en S3 == manifest.
s3 = Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
bucket = KbDocument::KB_BUCKET
remote = s3.get_object(bucket: bucket, key: expected_key).body.read
remote_sha = Digest::SHA256.hexdigest(remote)
status = remote_sha == expected_sha ? "OK" : "MISMATCH"
puts "S3 s3://#{bucket}/#{expected_key}"
puts "S3 SHA-256: #{remote_sha} [#{status}]"
puts "KbDocument: #{KbDocument.find_by(s3_key: expected_key)&.id.inspect}"
abort("S3 bytes do not match the manifest") unless status == "OK"
