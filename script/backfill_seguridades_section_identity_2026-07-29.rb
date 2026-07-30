# frozen_string_literal: true

# Fase 2 (puntos 3-5) de docs/RAG_PRECISION_V2_PLAN_2026-07-29.md — backfill de
# metadata SOLO de `section_identity` sobre los 97 sidecars de SEGURIDADES 1.1-1.
#
# Decisión y revisión del diff:
#   docs/RAG_SEGURIDADES_METADATA_BACKFILL_FASE2_DECISION_2026-07-29.md
#
# Uso:
#   bundle exec ruby script/backfill_seguridades_section_identity_2026-07-29.rb
#       → dry-run: no escribe en S3. Emite el diff a tmp/.
#   bundle exec ruby script/backfill_seguridades_section_identity_2026-07-29.rb --apply
#       → respalda los 97 originales y escribe los nuevos sidecars.
#
# Invariantes de seguridad (el script aborta si alguna falla):
#   1. Solo se toca `*.metadata.json`. Los `chunk_N.txt` nunca se escriben.
#   2. La ÚNICA clave añadida es `section_identity`. Ninguna clave existente
#      cambia de valor ni de orden (se verifica por round-trip JSON).
#   3. Antes de escribir, cada objeto de S3 debe coincidir byte a byte con la
#      copia local verificada (ETag == MD5 local). Si PROD cambió, aborta.
#   4. El respaldo se escribe FUERA de `bulk_chunks/` (regla de AGENTS.md:
#      ese prefijo es lo único que ingesta el data source de Bedrock).
#   5. NO dispara sincronización del Knowledge Base. El cambio queda inerte en
#      el índice vectorial hasta que un ingestion job se autorice aparte.
#
# No requiere Rails ni base de datos. Requiere credenciales AWS con permiso de
# lectura/escritura sobre el prefijo de chunks.

require "json"
require "digest"
require "fileutils"
require "time"
require "aws-sdk-s3"

REPO_ROOT   = File.expand_path("..", __dir__)
SOURCE_DIR  = ENV.fetch("BACKFILL_SOURCE_DIR", File.join(REPO_ROOT, "tmp/pdfs/seguridades_audit/production_chunks"))
BUCKET      = ENV.fetch("BACKFILL_BUCKET", "multimodal-source-destination")
ACCOUNT_ID  = "1"
DOCUMENT_ID = "b61f5d54-ff42-414a-97b7-01682d16f4b5"
CHUNK_PREFIX  = "bulk_chunks/#{ACCOUNT_ID}/#{DOCUMENT_ID}"
BACKUP_PREFIX = "sidecar_backups/#{ACCOUNT_ID}/#{DOCUMENT_ID}"
DIFF_PATH   = ENV.fetch("BACKFILL_DIFF_OUTPUT", File.join(REPO_ROOT, "tmp/rag_seguridades_section_identity_backfill_diff_2026-07-29.json"))

APPLY = ARGV.include?("--apply")

# Verdad-terreno revisada contra el PDF renderizado (páginas del archivo PDF).
# El script DERIVA las divisorias por forma y sólo usa esta tabla como aserción:
# si la derivación no coincide exactamente, aborta en vez de escribir.
# Ver §3 del documento de decisión.
EXPECTED_SECTIONS = [
  [ 2,  "ALJO" ],
  [ 8,  "CARLOS SILVA" ],
  [ 15, "CTA" ],
  [ 23, "EDEL" ],
  [ 27, "ELECMEGON" ],
  [ 35, "ENIER" ],
  [ 37, "EXCELSIOR" ],
  [ 41, "FAIN" ],
  [ 47, "HATS - ASOCIADOS" ],
  [ 49, "INELCA" ],
  [ 51, "KONE" ],
  [ 54, "MP" ],
  [ 60, "ORONA" ],
  [ 66, "OTIS" ],
  [ 70, "RECOBA" ],
  [ 80, "SCHINDLER" ],
  [ 87, "SISTEL" ],
  [ 92, "THYSSEN" ]
].freeze

# ChunkMergerService::SECTION_IDENTITY_MAX_CHARS — misma cota que el contrato v7,
# para que un backfill no pueda introducir un valor que la ingesta rechazaría.
SECTION_IDENTITY_MAX_CHARS = 60

def abort_with(message)
  warn "ABORT: #{message}"
  exit 1
end

# --- 1. Cargar la copia local -------------------------------------------------

abort_with("no existe el directorio fuente #{SOURCE_DIR}") unless Dir.exist?(SOURCE_DIR)

records = Dir.children(SOURCE_DIR)
  .select { |name| name.end_with?(".metadata.json") }
  .map do |sidecar_name|
    body_name    = sidecar_name.sub(/\.metadata\.json\z/, "")
    sidecar_path = File.join(SOURCE_DIR, sidecar_name)
    body_path    = File.join(SOURCE_DIR, body_name)
    abort_with("falta el cuerpo #{body_name} para #{sidecar_name}") unless File.file?(body_path)

    sidecar_raw = File.read(sidecar_path)
    parsed      = JSON.parse(sidecar_raw)
    attributes  = parsed["metadataAttributes"] or abort_with("#{sidecar_name} sin metadataAttributes")

    {
      chunk_file:   body_name,
      sidecar_name: sidecar_name,
      sidecar_raw:  sidecar_raw,
      parsed:       parsed,
      attributes:   attributes,
      page_number:  Integer(attributes["page_number"], exception: false),
      body:         File.read(body_path)
    }
  end
  .sort_by { |record| [ record[:page_number] || Float::INFINITY, record[:chunk_file] ] }

abort_with("se esperaban 97 sidecars, hay #{records.size}") unless records.size == 97

missing_page = records.reject { |record| record[:page_number]&.positive? }
abort_with("#{missing_page.size} sidecars sin page_number utilizable") if missing_page.any?

already = records.select { |record| record[:attributes].key?("section_identity") }
abort_with("#{already.size} sidecars YA traen section_identity — revisar antes de reescribir") if already.any?

# --- 2. Derivar las divisorias por forma, sin conocimiento de marcas ----------
#
# Una divisoria de marca es una página cuyo cuerpo NO declara encabezado `## ` ni
# línea `**Section:**`: es una diapositiva de portada que sólo rotula la marca y
# enumera sus modelos. La etiqueta de la sección es su PRIMER search alias — el
# alias que la propia página imprime como título. Cero listas de fabricantes.

def divider?(body)
  return false if body.lines.any? { |line| line.match?(/\A##\s+/) }

  !body.match?(/^\*\*Section:\*\*/)
end

def first_search_alias(body)
  match = body.match(/^\[SEARCH_ALIASES:\s*(.+?)\]\s*$/)
  return nil unless match

  match[1].split(",").map(&:strip).reject(&:empty?).first
end

derived_sections = records.filter_map do |record|
  next unless divider?(record[:body])

  label = first_search_alias(record[:body])
  abort_with("divisoria p#{record[:page_number]} (#{record[:chunk_file]}) sin SEARCH_ALIASES") if label.nil?
  [ record[:page_number], label ]
end

if derived_sections != EXPECTED_SECTIONS
  warn "Derivado:"
  derived_sections.each { |page, label| warn "  p#{page} #{label}" }
  warn "Esperado:"
  EXPECTED_SECTIONS.each { |page, label| warn "  p#{page} #{label}" }
  abort_with("la derivación por forma no coincide con la verdad-terreno revisada")
end

too_long = derived_sections.select { |_page, label| label.length > SECTION_IDENTITY_MAX_CHARS }
abort_with("etiquetas más largas que el contrato v7: #{too_long.inspect}") if too_long.any?

# --- 3. Arrastrar la identidad hacia adelante (semántica ChunkMergerService) ---

section_by_page = derived_sections.to_h
current = nil
records.each do |record|
  current = section_by_page[record[:page_number]] || current
  abort_with("p#{record[:page_number]} quedó sin sección: no hay divisoria previa") if current.nil?
  record[:section_identity] = current
end

# --- 4. Construir el nuevo sidecar y verificar que el diff sea SOLO la clave ---

records.each do |record|
  roundtrip = JSON.generate(record[:parsed])
  unless roundtrip == record[:sidecar_raw]
    abort_with("round-trip JSON no idéntico en #{record[:sidecar_name]} — el diff no sería sólo la clave nueva")
  end

  updated = record[:parsed].dup
  attributes = record[:attributes].dup
  attributes["section_identity"] = record[:section_identity]
  updated["metadataAttributes"] = attributes

  record[:new_raw] = JSON.generate(updated)
  record[:old_sha256] = Digest::SHA256.hexdigest(record[:sidecar_raw])
  record[:new_sha256] = Digest::SHA256.hexdigest(record[:new_raw])
  record[:old_md5]    = Digest::MD5.hexdigest(record[:sidecar_raw])

  # El nuevo contenido debe ser el viejo con exactamente una clave añadida al final.
  expected_suffix = ",\"section_identity\":#{JSON.generate(record[:section_identity])}}}"
  unless record[:new_raw] == record[:sidecar_raw].sub(/\}\}\z/, "") + expected_suffix
    abort_with("el nuevo sidecar de #{record[:sidecar_name]} no es el original + section_identity")
  end
end

# --- 5. Diff revisable --------------------------------------------------------

section_rows = derived_sections.each_with_index.map do |(page, label), index|
  last_page = index + 1 < derived_sections.size ? derived_sections[index + 1][0] - 1 : records.last[:page_number]
  group = records.select { |record| record[:section_identity] == label }
  {
    "label" => label,
    "divider_page" => page,
    "first_page" => page,
    "last_page" => last_page,
    "chunk_count" => group.size,
    "chunk_files" => group.map { |record| record[:chunk_file] }
  }
end

diff = {
  "generated_at" => Time.now.utc.iso8601,
  "bucket" => BUCKET,
  "chunk_prefix" => CHUNK_PREFIX,
  "account_id" => ACCOUNT_ID,
  "document_id" => DOCUMENT_ID,
  "mode" => APPLY ? "apply" : "dry_run",
  "key_added" => "section_identity",
  "keys_changed" => [],
  "keys_removed" => [],
  "bodies_touched" => 0,
  "sidecars_total" => records.size,
  "sidecars_changed" => records.size,
  "sections" => section_rows,
  "rows" => records.map do |record|
    {
      "chunk_file" => record[:chunk_file],
      "s3_key" => "#{CHUNK_PREFIX}/#{record[:sidecar_name]}",
      "page_number" => record[:page_number],
      "section_identity_before" => nil,
      "section_identity_after" => record[:section_identity],
      "sha256_before" => record[:old_sha256],
      "sha256_after" => record[:new_sha256]
    }
  end
}

FileUtils.mkdir_p(File.dirname(DIFF_PATH))
File.write(DIFF_PATH, JSON.pretty_generate(diff))

puts "SEGURIDADES section_identity backfill — #{APPLY ? 'APPLY' : 'DRY RUN'}"
puts "  bucket/prefijo : s3://#{BUCKET}/#{CHUNK_PREFIX}"
puts "  sidecars        : #{records.size} (todos reciben section_identity)"
puts "  cuerpos .txt    : 0 escrituras"
puts "  claves alteradas: ninguna; sólo se añade section_identity"
puts "  diff            : #{DIFF_PATH}"
puts
puts "  Secciones derivadas (#{section_rows.size}):"
section_rows.each do |row|
  puts format("    %-18s p%-3d–%-3d  %2d chunks", row["label"], row["first_page"], row["last_page"], row["chunk_count"])
end

unless APPLY
  puts
  puts "  Dry run: no se escribió nada. Revisar el diff y volver a correr con --apply."
  exit 0
end

# --- 6. Aplicar ---------------------------------------------------------------

s3 = Aws::S3::Client.new

puts
puts "  Verificando que PROD siga idéntico a la copia verificada…"
records.each do |record|
  key = "#{CHUNK_PREFIX}/#{record[:sidecar_name]}"
  head = begin
    s3.head_object(bucket: BUCKET, key: key)
  rescue Aws::S3::Errors::NotFound
    abort_with("#{key} no existe en S3")
  end
  remote_etag = head.etag.to_s.delete('"')
  unless remote_etag == record[:old_md5]
    abort_with("#{key} cambió en PROD (etag=#{remote_etag}, esperado=#{record[:old_md5]}) — no se escribe nada")
  end
end
puts "  OK: 97/97 objetos coinciden."

stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
backup_prefix = "#{BACKUP_PREFIX}/#{stamp}"
local_backup  = File.join(REPO_ROOT, "tmp/rag_seguridades_sidecar_backup_#{stamp}")
FileUtils.mkdir_p(local_backup)

puts "  Respaldando originales…"
records.each do |record|
  File.write(File.join(local_backup, record[:sidecar_name]), record[:sidecar_raw])
  s3.put_object(
    bucket: BUCKET,
    key: "#{backup_prefix}/#{record[:sidecar_name]}",
    body: record[:sidecar_raw],
    content_type: "application/json"
  )
end
hash_manifest = records.map do |record|
  { "sidecar" => record[:sidecar_name], "sha256_before" => record[:old_sha256], "sha256_after" => record[:new_sha256] }
end
manifest_json = JSON.pretty_generate(
  "stamp" => stamp, "bucket" => BUCKET, "chunk_prefix" => CHUNK_PREFIX,
  "backup_prefix" => backup_prefix, "sidecars" => hash_manifest
)
File.write(File.join(local_backup, "HASHES.json"), manifest_json)
s3.put_object(bucket: BUCKET, key: "#{backup_prefix}/HASHES.json", body: manifest_json, content_type: "application/json")
puts "  Respaldo: s3://#{BUCKET}/#{backup_prefix} y #{local_backup}"

puts "  Escribiendo sidecars…"
written = 0
records.each do |record|
  s3.put_object(
    bucket: BUCKET,
    key: "#{CHUNK_PREFIX}/#{record[:sidecar_name]}",
    body: record[:new_raw],
    content_type: "application/json"
  )
  written += 1
end
puts "  Escritos: #{written}"

puts "  Verificando post-escritura…"
records.each do |record|
  key = "#{CHUNK_PREFIX}/#{record[:sidecar_name]}"
  actual = s3.get_object(bucket: BUCKET, key: key).body.read
  unless Digest::SHA256.hexdigest(actual) == record[:new_sha256]
    abort_with("#{key} no coincide tras la escritura — restaurar desde s3://#{BUCKET}/#{backup_prefix}")
  end
end
puts "  OK: 97/97 verificados."
puts
puts "  NO se disparó sincronización del Knowledge Base. El índice vectorial sigue"
puts "  sirviendo la metadata anterior hasta que se autorice un ingestion job."
