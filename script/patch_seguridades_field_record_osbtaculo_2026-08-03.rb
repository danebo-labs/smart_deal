# frozen_string_literal: true

# Fase 3, Rama Generación, paso 2 de docs/rag/plan_quirurgico_precision_2026-08-02.md
# (decisión #3 del dueño del producto): repara la etiqueta corrupta "OSBTACULO"
# (transposición de letras de "OBSTACULO") dentro de los bloques FIELD_RECORD de
# SEGURIDADES 1.1-1. Causa raíz medida en el fallo `holdout_arca_p36_torque` del
# holdout v1 (docs/rag/holdout_v1_resultado_2026-08-03.md §3): el chunk de ARCA III
# (pág. 64) trae la tabla correcta "SERIE OBSTÁCULO" y, más abajo, un FIELD_RECORD
# con "EVIDENCE: P36 SERIE OSBTACULO" — el modelo citó la copia corrupta.
#
# Alcance de este script — confirmado con `aws s3 sync` de los 97 cuerpos
# (bulk_chunks/1/b61f5d54-.../chunk_N.txt) y grep, no sólo el chunk_62 de la
# instrucción original: la cadena "OSBTACULO" aparece en 6 chunks, 7 apariciones,
# SIEMPRE dentro de una línea `EVIDENCE:` de un bloque FIELD_RECORD, y en los 6
# casos el mismo chunk escribe la forma correcta ("OBSTÁCULO"/"OBSTACULO") en su
# propia tabla o prosa visible — evidencia de que es un defecto de la pasada de
# extracción de FIELD_RECORD, no una errata del documento original transcrita
# verbatim (a diferencia de otras cadenas parecidas encontradas en el mismo grep,
# ver nota "Alcance NO cubierto" abajo).
#
# Alcance NO cubierto (hallazgo para el dueño del producto, no ejecutado aquí):
# el mismo grep encontró otras 6 familias de cadenas con apariencia de typo
# (CERRRADA, SEGURIIDAD/PRINCPAL, SEGURDAD, EXTERORES, ACUÑAIENTO, REVISON) en
# ~30 chunks adicionales. Al menos DOS de ellas están marcadas explícitamente
# como erratas del documento ORIGINAL, preservadas a propósito:
#   - chunk_73.txt línea 23: "La descripción 'SERIE SEGURIIDAD PRINCPAL' se
#     transcribe verbatim tal como aparece en el diagrama (probable errata
#     tipográfica en el original)."
#   - chunk_79.txt línea 23: "el texto original escribe 'SEGURDAD' (sin 'I') para
#     T5 — se conserva tal cual el documento."
# Corregirlas sería violar la fidelidad documentaria (RAG First / Safety First de
# AGENTS.md), no reparar una corrupción de ingesta. Las demás familias
# (EXTERORES, CERRRADA, ACUÑAIENTO, REVISON) no tienen ese disclaimer explícito
# pero tampoco tienen la firma limpia de "tabla correcta + FIELD_RECORD corrupto
# en el mismo chunk" que sí tiene OSBTACULO en los 6 chunks de este script (p.ej.
# chunk_12.txt: "EXTERORES" aparece también en la tabla visible, no sólo en
# FIELD_RECORD — no se puede distinguir sin cotejar el PDF/OCR, fuera de
# presupuesto y de la autorización explícita de esta fase). Se documentan como
# hallazgo abierto en el plan; no se tocan en esta pasada.
#
# Cost: zero Claude calls. PutObject on the same 6 keys + one KB ingestion job
# (Titan re-embeds only the changed chunks).
#
# Usage:
#   RAG_CHUNK_PATCH_CONFIRM=1 bin/rails runner \
#     script/patch_seguridades_field_record_osbtaculo_2026-08-03.rb

abort("Set RAG_CHUNK_PATCH_CONFIRM=1 to run (mutates the production KB)") unless ENV["RAG_CHUNK_PATCH_CONFIRM"] == "1"

require "digest"
require "fileutils"
require "time"

ENV["KNOWLEDGE_BASE_S3_BUCKET"]    = "multimodal-source-destination"
ENV["BEDROCK_KNOWLEDGE_BASE_ID"]   = "Y7RZWMFJSR"
ENV["BEDROCK_BULK_DATA_SOURCE_ID"] = "PJ0N58DMHG"
ENV["BEDROCK_DATA_SOURCE_ID"]      = "PJ0N58DMHG"
ENV["AWS_REGION"]                  = "us-east-1"

ActiveJob::Base.queue_adapter = :inline

DOCUMENT_ID  = "b61f5d54-ff42-414a-97b7-01682d16f4b5"
CHUNK_PREFIX = "bulk_chunks/1/#{DOCUMENT_ID}"
REFERENCE_DIR = Rails.root.join("tmp/rag_seguridades_field_record_osbtaculo_2026-08-03/backup")
TYPO    = "OSBTACULO"
FIXED   = "OBSTACULO"

# chunk number => expected occurrences of TYPO, verified by grep against the
# live S3 copy fetched moments before writing this script (2026-08-03).
TARGETS = {
  29 => 1,
  30 => 1,
  31 => 1,
  32 => 1,
  62 => 2,
  67 => 1
}.freeze

def abort_with(message)
  warn "ABORT: #{message}"
  exit 1
end

s3 = S3DocumentsService.new
records = TARGETS.map do |chunk_number, expected_count|
  key = "#{CHUNK_PREFIX}/chunk_#{chunk_number}.txt"
  reference_path = REFERENCE_DIR.join("chunk_#{chunk_number}.txt")
  abort_with("no existe la copia de referencia #{reference_path}") unless File.exist?(reference_path)

  reference_body = File.binread(reference_path)
  found = reference_body.scan(TYPO).size
  abort_with("#{key}: se esperaban #{expected_count} apariciones de #{TYPO}, la referencia tiene #{found}") if found != expected_count

  outside_field_record = false
  in_block = false
  reference_body.each_line do |line|
    in_block = true if line.start_with?("FIELD_RECORD:")
    outside_field_record ||= (!in_block && line.include?(TYPO))
    in_block = false if line.start_with?("END_FIELD_RECORD")
  end
  abort_with("#{key}: #{TYPO} aparece fuera de un bloque FIELD_RECORD — no es el patrón esperado") if outside_field_record

  patched_body = reference_body.gsub(TYPO, FIXED)
  abort_with("#{key}: el patch no cambió nada") if patched_body == reference_body
  abort_with("#{key}: quedan apariciones de #{TYPO} tras el patch") if patched_body.include?(TYPO)

  before_fixed = reference_body.scan(FIXED).size
  after_fixed  = patched_body.scan(FIXED).size
  unless after_fixed == before_fixed + expected_count
    abort_with("#{key}: el conteo de '#{FIXED}' tras el patch no es el esperado (antes=#{before_fixed}, después=#{after_fixed})")
  end

  {
    chunk_number: chunk_number,
    key: key,
    reference_body: reference_body,
    patched_body: patched_body,
    old_md5: Digest::MD5.hexdigest(reference_body),
    old_sha256: Digest::SHA256.hexdigest(reference_body),
    new_sha256: Digest::SHA256.hexdigest(patched_body)
  }
end

puts "=" * 80
puts "SEGURIDADES FIELD_RECORD OSBTACULO patch — #{records.size} chunks"
records.each do |r|
  puts "  #{r[:key]}  (#{TARGETS[r[:chunk_number]]}x, sha #{r[:old_sha256][0, 12]} -> #{r[:new_sha256][0, 12]})"
end
puts "=" * 80

require "aws-sdk-s3"
raw_s3 = Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))

puts "Verificando que PROD siga idéntico a la copia de referencia…"
records.each do |r|
  head = begin
    raw_s3.head_object(bucket: s3.bucket_name, key: r[:key])
  rescue Aws::S3::Errors::NotFound
    abort_with("#{r[:key]} no existe en S3")
  end
  remote_etag = head.etag.to_s.delete('"')
  abort_with("#{r[:key]} cambió en PROD (etag=#{remote_etag}, esperado=#{r[:old_md5]}) — no se escribe nada") unless remote_etag == r[:old_md5]
end
puts "  OK: #{records.size}/#{records.size} objetos coinciden con la referencia."

stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
backup_prefix = "chunk_body_backups/1/#{DOCUMENT_ID}/#{stamp}"
local_backup  = Rails.root.join("tmp/rag_seguridades_field_record_osbtaculo_2026-08-03/prod_backup_#{stamp}")
FileUtils.mkdir_p(local_backup)

puts "Respaldando originales…"
records.each do |r|
  filename = File.basename(r[:key])
  File.binwrite(local_backup.join(filename), r[:reference_body])
  s3.upload_binary("#{backup_prefix}/#{filename}", r[:reference_body], "text/plain; charset=utf-8")
end
hash_manifest = records.map { |r| { "key" => r[:key], "sha256_before" => r[:old_sha256], "sha256_after" => r[:new_sha256] } }
manifest_json = JSON.pretty_generate("stamp" => stamp, "bucket" => s3.bucket_name, "backup_prefix" => backup_prefix, "chunks" => hash_manifest)
File.write(local_backup.join("HASHES.json"), manifest_json)
s3.upload_binary("#{backup_prefix}/HASHES.json", manifest_json, "application/json")
puts "  Respaldo: s3://#{s3.bucket_name}/#{backup_prefix} y #{local_backup}"

puts "Escribiendo chunks…"
records.each do |r|
  abort_with("upload failed for #{r[:key]}") unless s3.upload_text(r[:key], r[:patched_body])
end

puts "Verificando post-escritura…"
records.each do |r|
  actual = s3.download(r[:key])
  actual_sha = Digest::SHA256.hexdigest(actual)
  unless actual_sha == r[:new_sha256]
    abort_with("#{r[:key]} no coincide tras la escritura (sha=#{actual_sha}) — restaurar desde s3://#{s3.bucket_name}/#{backup_prefix}")
  end
end
puts "  OK: #{records.size}/#{records.size} verificados."

puts
puts "Disparando resync del KB (BulkKbSyncService)…"
sync_result = BulkKbSyncService.new.sync!(uploaded_filenames: [ "SEGURIDADES 1.1-1.pdf" ], locale: "es")
abort("KB sync did not start") unless sync_result
puts "  job_id:         #{sync_result[:job_id]}"
puts "  kb_id:          #{sync_result[:kb_id]}"
puts "  data_source_id: #{sync_result[:data_source_id]}"

require "aws-sdk-bedrockagent"
agent = Aws::BedrockAgent::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
status = "STARTING"
print "Polling ingestion job: "
90.times do
  status = agent.get_ingestion_job(
    knowledge_base_id: sync_result[:kb_id],
    data_source_id:    sync_result[:data_source_id],
    ingestion_job_id:  sync_result[:job_id]
  ).ingestion_job.status
  print "#{status} "
  break unless %w[STARTING IN_PROGRESS].include?(status)

  sleep 10
end
puts

abort("KB ingestion job ended with status #{status}") unless status == "COMPLETE"
puts "\nRESULT: OK — #{records.size} chunks patched (OSBTACULO -> OBSTACULO) and KB sync COMPLETE"
