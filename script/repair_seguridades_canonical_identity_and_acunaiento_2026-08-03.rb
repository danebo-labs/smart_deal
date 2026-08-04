# frozen_string_literal: true

# Fase 2 (puntos 2a + 2c) de docs/rag/plan_precision_definitiva_2026-08-03.md —
# ciclo 3. Dos correcciones de metadatos independientes, aplicadas en la misma
# pasada para compartir UN solo resync del KB (regla de la Fase 2):
#
# 2a. `canonical_name`/`aliases` de 91 sidecars llevan el valor de ALJO
#     ("ALJO Control Level 1B Altius" + 15 aliases 100% ALJO) pese a que
#     `section_identity` (ya backfilled y verificado 100% correcto en la
#     Fase 1, ciclo 3) dice la marca real de la página. Higiene de datos —
#     no bloquea el gate v3 por sí sola (eso lo hace 2d, el guard). Alcance:
#     SOLO los 91 sidecars cuyo `canonical_name` es el valor contaminado Y
#     `section_identity` != "ALJO"; los 6 sidecars de la sección ALJO real no
#     se tocan (su canonical_name ya es correcto).
#
#     Verdad-terreno: `section_identity` de cada sidecar (ya publicado y
#     verificado, no se re-deriva aquí) + la lista de modelos impresos en la
#     misma divisoria, medida en docs/rag/gate_a_medicion_topologia.md §5.2
#     (18/18 coincide con el Apéndice E). Alcance DELIBERADAMENTE a nivel de
#     SECCIÓN (marca), no de página individual: precisar el modelo exacto de
#     cada página exigiría repetir el ejercicio de título-por-página de §5.3
#     ("si la Fase 8 lo necesita, que rehaga ese corte con su propio
#     criterio") — eso es una pasada more cara y no es lo que este ciclo
#     necesita para destrabar el gate. `canonical_name` pasa a ser la marca
#     (idéntica al `section_identity` ya verificado); los modelos de la
#     sección entran como aliases individuales, más los dos alias de
#     documento ("SEGURIDADES 1.1", "SEGURIDADES 1.1-1") que ya traía cada
#     sidecar y son válidos para cualquier sección.
#
# 2c. Repara `ACUÑAIENTO` → `ACUÑAMIENTO` en chunk_94 (decisión #5 del dueño
#     del producto): mismo perfil limpio que OSBTACULO
#     (script/patch_seguridades_field_record_osbtaculo_2026-08-03.rb) — 1 sola
#     aparición, dentro de un bloque FIELD_RECORD (línea EVIDENCE), con la
#     forma correcta "ACUÑAMIENTO" ya presente en la tabla/prosa visible del
#     mismo chunk (líneas 37, 70, 87).
#
# Invariantes de seguridad (el script aborta si alguna falla):
#   1. Los sidecars: el ÚNICO cambio de valor es `canonical_name` y `aliases`.
#      Ninguna otra clave cambia de valor, se añade ni se quita (round-trip
#      verificado).
#   2. El cuerpo: solo chunk_94.txt se escribe, solo se sustituye la cadena
#      TYPO por FIXED, verificado por conteo antes/después.
#   3. Antes de escribir, cada objeto de S3 debe coincidir byte a byte con la
#      copia de referencia local (ETag == MD5 local, sincronizada momentos
#      antes de escribir este script). Si PROD cambió, aborta sin escribir
#      nada.
#   4. Backup de todos los originales (sidecars + cuerpo) a S3 fuera de
#      `bulk_chunks/` + copia local, con manifiesto de hashes, antes de
#      escribir.
#   5. Un solo `BulkKbSyncService` al final, cubriendo 2a + 2c.
#
# Uso:
#   RAG_CHUNK_PATCH_CONFIRM=1 bin/rails runner \
#     script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb

abort("Set RAG_CHUNK_PATCH_CONFIRM=1 to run (mutates the production KB)") unless ENV["RAG_CHUNK_PATCH_CONFIRM"] == "1"

require "json"
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

REFERENCE_SIDECAR_DIR = Rails.root.join("tmp/rag_seguridades_ciclo3_fase2_2026-08-03/reference_sidecars")
REFERENCE_BODY_DIR    = Rails.root.join("tmp/rag_seguridades_ciclo3_fase2_2026-08-03/reference_bodies")

CONTAMINATED_CANONICAL_NAME = "ALJO Control Level 1B Altius"
DOCUMENT_WIDE_ALIASES = [ "SEGURIDADES 1.1", "SEGURIDADES 1.1-1" ].freeze

# docs/rag/gate_a_medicion_topologia.md §5.2 — "Modelos impresos en el
# divisor", 18/18 verificado contra el Apéndice E. ALJO queda fuera: sus 6
# sidecars ya tienen canonical_name/aliases correctos y no se tocan.
MODELS_BY_SECTION = {
  "CARLOS SILVA"     => [ "HIDRA TPR50", "HIDRA TPR60", "HIDRA TPR70", "SIRIUS", "KDT EVO" ],
  "CTA"              => [ "M8PC", "SR8P", "PREMONTADA", "CR8PH", "MR08" ],
  "EDEL"             => [ "K2", "K3" ],
  "ELECMEGON"        => [ "EM 3000", "EM 2000", "EM 4000", "EM 1000" ],
  "ENIER"            => [ "MXL1" ],
  "EXCELSIOR"        => [ "EXCELSIOR", "TOKIBAT 2007" ],
  "FAIN"             => [ "FAIN", "EKM66" ],
  "HATS - ASOCIADOS" => [ "ZEUS" ],
  "INELCA"           => [ "HOMELIFT" ],
  "KONE"             => [ "MONOESPACE", "EPB" ],
  "MP"               => [ "5000", "MICROBASIC", "VIA SERIE" ],
  "ORONA"            => [ "ARCA", "ARCA BASICO", "ARCA II", "ARCA III" ],
  "OTIS"             => [ "LB II", "LCB II", "GEN II" ],
  "RECOBA"           => [ "KSA 18", "EKM 64", "EKM 66" ],
  "SCHINDLER"        => [ "MICONIC LX", "SMART 001 CRIPS", "SMART 001", "MICONIC BX -6200", "BIONIC 5 REL.2 -3300", "BIONIC 5 REL.4 -3300" ],
  "SISTEL"           => [ "TW1 INAPELSA", "TW1 ELECTRICO EMBARBA", "TW1 HIDRAULICO EMBARBA", "DELTA +" ],
  "THYSSEN"          => [ "SERIE E", "SERIE B", "SERIE F", "SERIE CMC 3", "SERIE CMC 4", "SERIE CMC 4+" ]
}.freeze

TYPO_CHUNK_NUMBER = 94
TYPO  = "ACUÑAIENTO"
FIXED = "ACUÑAMIENTO"

def abort_with(message)
  warn "ABORT: #{message}"
  exit 1
end

# --- 1. Cargar la copia de referencia (sincronizada momentos antes) ----------

abort_with("no existe #{REFERENCE_SIDECAR_DIR}") unless Dir.exist?(REFERENCE_SIDECAR_DIR)
abort_with("no existe #{REFERENCE_BODY_DIR}") unless Dir.exist?(REFERENCE_BODY_DIR)

sidecar_files = Dir.children(REFERENCE_SIDECAR_DIR).select { |name| name.end_with?(".metadata.json") }
abort_with("se esperaban 97 sidecars de referencia, hay #{sidecar_files.size}") unless sidecar_files.size == 97

sidecar_records = sidecar_files.filter_map do |name|
  path = REFERENCE_SIDECAR_DIR.join(name)
  raw  = File.read(path)
  parsed = JSON.parse(raw)
  attributes = parsed.fetch("metadataAttributes")
  section_identity = attributes["section_identity"]
  canonical_name = attributes["canonical_name"]

  next nil unless canonical_name == CONTAMINATED_CANONICAL_NAME && section_identity != "ALJO"

  models = MODELS_BY_SECTION[section_identity] or
    abort_with("sidecar #{name}: section_identity #{section_identity.inspect} sin modelos en MODELS_BY_SECTION")

  new_canonical_name = section_identity
  new_aliases = ([ section_identity ] + models + DOCUMENT_WIDE_ALIASES).uniq

  updated_attributes = attributes.dup
  updated_attributes["canonical_name"] = new_canonical_name
  updated_attributes["aliases"] = new_aliases
  updated_parsed = parsed.merge("metadataAttributes" => updated_attributes)
  new_raw = JSON.generate(updated_parsed)

  # El único diff permitido: los VALORES de canonical_name y aliases. Ninguna
  # clave se añade, se quita, ni cambia de posición.
  reparsed_old = JSON.parse(JSON.generate(parsed))
  reparsed_new = JSON.parse(new_raw)
  diff_keys = attributes.keys.select { |key| reparsed_old["metadataAttributes"][key] != reparsed_new["metadataAttributes"][key] }
  unless diff_keys.sort == %w[aliases canonical_name]
    abort_with("#{name}: el diff no es exactamente canonical_name+aliases (fue #{diff_keys.inspect})")
  end
  if reparsed_old["metadataAttributes"].keys != reparsed_new["metadataAttributes"].keys
    abort_with("#{name}: el nuevo sidecar añade o quita claves")
  end

  {
    chunk_file: name.sub(/\.metadata\.json\z/, ""),
    sidecar_name: name,
    old_raw: raw,
    new_raw: new_raw,
    section_identity: section_identity,
    old_canonical_name: canonical_name,
    new_canonical_name: new_canonical_name,
    old_aliases: attributes["aliases"],
    new_aliases: new_aliases,
    old_md5: Digest::MD5.hexdigest(raw),
    old_sha256: Digest::SHA256.hexdigest(raw),
    new_sha256: Digest::SHA256.hexdigest(new_raw)
  }
end

abort_with("se esperaban 91 sidecars afectados, se encontraron #{sidecar_records.size}") unless sidecar_records.size == 91

# --- 2. Cargar y validar el parche de cuerpo (2c) ----------------------------

body_path = REFERENCE_BODY_DIR.join("chunk_#{TYPO_CHUNK_NUMBER}.txt")
abort_with("no existe #{body_path}") unless File.exist?(body_path)

reference_body = File.binread(body_path).force_encoding(Encoding::UTF_8)
abort_with("chunk_#{TYPO_CHUNK_NUMBER}: la referencia no es UTF-8 valido") unless reference_body.valid_encoding?
found = reference_body.scan(TYPO).size
abort_with("chunk_#{TYPO_CHUNK_NUMBER}: se esperaba 1 aparición de #{TYPO}, hay #{found}") if found != 1

outside_field_record = false
in_block = false
reference_body.each_line do |line|
  in_block = true if line.start_with?("FIELD_RECORD:")
  outside_field_record ||= (!in_block && line.include?(TYPO))
  in_block = false if line.start_with?("END_FIELD_RECORD")
end
abort_with("chunk_#{TYPO_CHUNK_NUMBER}: #{TYPO} aparece fuera de un bloque FIELD_RECORD") if outside_field_record
abort_with("chunk_#{TYPO_CHUNK_NUMBER}: no tiene ya la forma correcta #{FIXED} en otra parte") unless reference_body.include?(FIXED)

patched_body = reference_body.gsub(TYPO, FIXED)
abort_with("chunk_#{TYPO_CHUNK_NUMBER}: el patch no cambió nada") if patched_body == reference_body
abort_with("chunk_#{TYPO_CHUNK_NUMBER}: quedan apariciones de #{TYPO}") if patched_body.include?(TYPO)

body_record = {
  chunk_number: TYPO_CHUNK_NUMBER,
  key: "#{CHUNK_PREFIX}/chunk_#{TYPO_CHUNK_NUMBER}.txt",
  old_body: reference_body,
  new_body: patched_body,
  old_md5: Digest::MD5.hexdigest(reference_body),
  old_sha256: Digest::SHA256.hexdigest(reference_body),
  new_sha256: Digest::SHA256.hexdigest(patched_body)
}

# --- 3. Resumen ---------------------------------------------------------------

puts "=" * 80
puts "SEGURIDADES canonical_identity (2a) + ACUÑAIENTO (2c) — #{sidecar_records.size} sidecars + 1 cuerpo"
sidecar_records.group_by { |r| r[:section_identity] }.sort.each do |section, records|
  puts "  #{section.ljust(18)} #{records.size} sidecars -> canonical_name=#{records.first[:new_canonical_name]}"
end
puts "  #{body_record[:key]}  (1x, sha #{body_record[:old_sha256][0, 12]} -> #{body_record[:new_sha256][0, 12]})"
puts "=" * 80

require "aws-sdk-s3"
raw_s3 = Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
s3 = S3DocumentsService.new

puts "Verificando que PROD siga idéntico a la copia de referencia…"
all_keys = sidecar_records.map { |r| [ "#{CHUNK_PREFIX}/#{r[:sidecar_name]}", r[:old_md5] ] } +
  [ [ body_record[:key], body_record[:old_md5] ] ]
all_keys.each do |key, expected_md5|
  head = begin
    raw_s3.head_object(bucket: s3.bucket_name, key: key)
  rescue Aws::S3::Errors::NotFound
    abort_with("#{key} no existe en S3")
  end
  remote_etag = head.etag.to_s.delete('"')
  abort_with("#{key} cambió en PROD (etag=#{remote_etag}, esperado=#{expected_md5}) — no se escribe nada") unless remote_etag == expected_md5
end
puts "  OK: #{all_keys.size}/#{all_keys.size} objetos coinciden con la referencia."

stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
backup_prefix = "chunk_body_backups/1/#{DOCUMENT_ID}/#{stamp}_ciclo3_fase2"
local_backup  = Rails.root.join("tmp/rag_seguridades_ciclo3_fase2_2026-08-03/prod_backup_#{stamp}")
FileUtils.mkdir_p(local_backup)

puts "Respaldando originales…"
sidecar_records.each do |r|
  File.binwrite(local_backup.join(r[:sidecar_name]), r[:old_raw])
  s3.upload_binary("#{backup_prefix}/#{r[:sidecar_name]}", r[:old_raw], "application/json")
end
File.binwrite(local_backup.join("chunk_#{TYPO_CHUNK_NUMBER}.txt"), body_record[:old_body])
s3.upload_binary("#{backup_prefix}/chunk_#{TYPO_CHUNK_NUMBER}.txt", body_record[:old_body], "text/plain; charset=utf-8")

hash_manifest = sidecar_records.map { |r| { "key" => "#{CHUNK_PREFIX}/#{r[:sidecar_name]}", "sha256_before" => r[:old_sha256], "sha256_after" => r[:new_sha256] } } +
  [ { "key" => body_record[:key], "sha256_before" => body_record[:old_sha256], "sha256_after" => body_record[:new_sha256] } ]
manifest_json = JSON.pretty_generate("stamp" => stamp, "bucket" => s3.bucket_name, "backup_prefix" => backup_prefix, "objects" => hash_manifest)
File.write(local_backup.join("HASHES.json"), manifest_json)
s3.upload_binary("#{backup_prefix}/HASHES.json", manifest_json, "application/json")
puts "  Respaldo: s3://#{s3.bucket_name}/#{backup_prefix} y #{local_backup}"

puts "Escribiendo sidecars (2a)…"
sidecar_records.each do |r|
  abort_with("upload failed for #{r[:sidecar_name]}") unless s3.upload_text("#{CHUNK_PREFIX}/#{r[:sidecar_name]}", r[:new_raw])
end
puts "Escribiendo cuerpo (2c)…"
abort_with("upload failed for chunk_#{TYPO_CHUNK_NUMBER}.txt") unless s3.upload_text(body_record[:key], body_record[:new_body])

puts "Verificando post-escritura…"
sidecar_records.each do |r|
  actual = s3.download("#{CHUNK_PREFIX}/#{r[:sidecar_name]}")
  actual_sha = Digest::SHA256.hexdigest(actual)
  unless actual_sha == r[:new_sha256]
    abort_with("#{r[:sidecar_name]} no coincide tras la escritura — restaurar desde s3://#{s3.bucket_name}/#{backup_prefix}")
  end
end
actual_body = s3.download(body_record[:key])
unless Digest::SHA256.hexdigest(actual_body) == body_record[:new_sha256]
  abort_with("chunk_#{TYPO_CHUNK_NUMBER}.txt no coincide tras la escritura — restaurar desde s3://#{s3.bucket_name}/#{backup_prefix}")
end
puts "  OK: #{sidecar_records.size + 1}/#{sidecar_records.size + 1} verificados."

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

# Ciclo 5 Fase 1 (H1/H2, 2026-08-04): this repair originally shipped with no
# Rag::SectionNeighborExpander cache invalidation hook, so the corrected
# canonical_name above kept serving stale ("ALJO Control Level 1B Altius")
# for up to 30 days from Rails.cache after S3/Bedrock were already fixed. No
# explicit call is needed here anymore: every `s3.upload_text` above (91
# sidecars + chunk_94.txt) already invalidated
# Rag::SectionNeighborExpander's cached page index for CHUNK_PREFIX as it
# ran, via S3DocumentsService#upload_text (see app/services/rag/AGENTS.md,
# "Chunk Repair Cache Invalidation"). A script that ever bypasses
# S3DocumentsService for a bulk_chunks/ write must call
# Rag::SectionNeighborExpander.invalidate!(prefix) itself instead.

puts "\nRESULT: OK — #{sidecar_records.size} sidecars (2a) + 1 chunk body (2c) patched, KB sync COMPLETE"
