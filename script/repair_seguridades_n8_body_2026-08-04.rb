# frozen_string_literal: true

# Fase 3 de docs/rag/plan_ciclo5_resolucion_decision9_2026-08-04.md — parche
# determinístico SIN LLM de los cuerpos de chunk contaminados por N8 (identidad
# "ALJO Control Level 1B Altius" incrustada en páginas que no son de ALJO).
#
# HISTORIA (2026-08-04): la hipótesis de LÍNEA ÚNICA del borrador original de
# esta fase quedó FALSIFICADA contra los 97 cuerpos verificados (H10). El
# regex literal del plan
# (`\*\*Document:\*\* ALJO Control Level 1B Altius \| Page \d+ \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED.*`)
# sólo coincide EXACTO con 1 de 96 cuerpos contaminados (chunk_43) — el modelo
# de visión nunca siguió un template fijo al obedecer la instrucción retirada
# en la Fase 2 ("Each section title must appear inside the chunk after the
# **Document:** header"), así que produjo 11 formas distintas de un bloque de
# 1-4 líneas, más 2 casos de contaminación FUERA de ese bloque (chunk_0: filas
# de tabla en la sección S0; chunk_36: línea suelta en prosa, línea 75).
#
# DECISIÓN HUMANA #10 — RESUELTA (2026-08-04): el dueño autorizó explícitamente
# "eliminar toda contaminación de N8" — Alcance A (bloque completo), la opción
# que este plan recomendaba.
#
# CAUSA RAÍZ (H3, ya removida en la Fase 2, commit 3873294): el prompt
# `app/prompts/batch_chunking_prompt.rb` ya NO instruye al modelo a emitir
# ningún encabezado de identidad dentro del cuerpo — verificado de nuevo en
# esta sesión, línea por línea, sin hallar ninguna instrucción residual que
# reproduzca N8 en una ingesta futura. Este script sólo limpia el DATO ya
# escrito con el prompt viejo.
#
# NOTA (2026-08-04, primera corrida real): el intento inicial pre-verificaba
# ETag de los 97 objetos contra la copia de referencia local
# `tmp/seguridades_chunks_2026-07-28/` y abortó en `chunk_23.txt` (drift real
# — el objeto vivo ya no coincide con esa copia de 2026-07-28; Fase 0 sólo
# muestreó 5 chunks distintos ese día, no éste). Corregido: el modo real ya NO
# depende del contenido de la referencia local para decidir qué escribir —
# descarga cada cuerpo EN VIVO y corre la misma detección de bloque sobre ese
# byte fresco. La referencia local sólo sirve para el modo diagnóstico (sin
# red) y como snapshot de qué 97 nombres de archivo esperar. S3 tiene
# versioning habilitado en PROD (confirmado por el dueño) — respaldo adicional
# más allá del backup explícito que este script igual hace.
#
# Uso:
#   bin/rails runner script/repair_seguridades_n8_body_2026-08-04.rb              # modo diagnóstico (sin red, sobre la copia local)
#   RAG_CHUNK_PATCH_CONFIRM=1 bin/rails runner script/repair_seguridades_n8_body_2026-08-04.rb  # modo real (descarga en vivo, muta producción)

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
EXPECTED_CHUNK_COUNT = 97

REFERENCE_BODY_DIR = Rails.root.join("tmp/seguridades_chunks_2026-07-28")
OUTPUT_DIR = Rails.root.join("tmp/ciclo5_fase3_2026-08-04")
FileUtils.mkdir_p(OUTPUT_DIR)

REAL_MODE = ENV["RAG_CHUNK_PATCH_CONFIRM"] == "1"

# Forma que el plan asumía "regular y greppeable" en el 96/97 — en la práctica
# sólo coincide con chunk_43 (ver diagnóstico de esta sesión, H10).
PLAN_LITERAL_REGEX = /\*\*Document:\*\* ALJO Control Level 1B Altius \| Page \d+ \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED.*/

# Detección de bloque real: empieza en la línea **Document:** y se extiende
# mientras las líneas siguientes sean continuaciones conocidas del mismo
# encabezado de identidad inyectado por el prompt viejo. Alcance A (decisión
# humana #10): se remueve el bloque COMPLETO, incluidas **Section:**/**Page:**
# — consistente con que `Bedrock::CitationProcessor::METADATA_LINE_PATTERN`
# (citation_processor.rb:143-144) ya trata esas líneas como ruido a filtrar en
# el excerpt de citación, y con la paridad profiláctica de la Fase 2 (un chunk
# nuevo no emite ningún header de este tipo).
DOC_LINE = /\A\*\*Document:\*\*/
BLOCK_CONTINUATION = /\A(\*\*Section:\*\*|\*\*Page:\*\*|ORIGINAL_FILE_NAME:|NORMALIZED_FILE_NAME:|SOURCE_URI:)/

# Casos especiales verificados manualmente contra la copia de referencia
# (2026-08-04): contaminación FUERA del bloque contiguo de identidad. Sin
# estos dos, quedaría residuo tras remover sólo el bloque (el script aborta si
# detecta cualquier residuo, ver más abajo). Aplicados por nombre de archivo,
# no por posición — siguen aplicando aunque el resto del cuerpo haya derivado.
STRAY_LINES = {
  # S0 / página ancla (p.2, ALJO real) — la tabla "## S0 chunk content" traía
  # 2 filas retiradas de la instrucción del prompt en la Fase 2 (ver diff de
  # `app/prompts/batch_chunking_prompt.rb`, commit 3873294).
  "chunk_0.txt" => [
    "| ORIGINAL_FILE_NAME | PIPELINE_INJECTED |\n",
    "| NORMALIZED_FILE_NAME | PIPELINE_INJECTED |\n"
  ].freeze,
  # Línea suelta en prosa (página 38, EXCELSIOR), inmediatamente después de
  # "Fabricante del sistema: EXCELSIOR" — contradice la marca correcta que el
  # propio chunk identifica una línea antes.
  "chunk_36.txt" => [
    "Sistema general: ALJO Control Level 1B Altius\n"
  ].freeze
}.freeze

def abort_with(message)
  warn "ABORT: #{message}"
  exit 1
end

# Aplica la detección de bloque + casos especiales a UN cuerpo. Devuelve un
# Hash de resultado; nunca escribe nada. Aborta el proceso completo si un caso
# especial esperado no aparece verbatim, o si la remoción propuesta dejaría
# residuo — nunca devuelve un resultado "contaminado" inseguro.
def analyze(name, body)
  abort_with("#{name}: cuerpo no es UTF-8 válido") unless body.valid_encoding?

  lines = body.lines
  doc_idx = lines.index { |l| l.match?(DOC_LINE) }
  return { file: name, contaminated: false, reason: "no **Document:** line", old_body: body } unless doc_idx

  unless lines[doc_idx].include?("ALJO Control Level 1B Altius")
    # chunk_90: "**Document:** PIPELINE_INJECTED" (sin nombre ALJO) — el único
    # cuerpo limpio de contaminación de IDENTIDAD; nunca se toca.
    return { file: name, contaminated: false, reason: "identity line present but not ALJO-named (chunk_90 case)", old_body: body }
  end

  block_end = doc_idx
  (doc_idx + 1...lines.size).each do |i|
    break unless lines[i].match?(BLOCK_CONTINUATION)
    block_end = i
  end

  removed_indices = (doc_idx..block_end).to_a
  Array(STRAY_LINES[name]).each do |stray|
    stray_idx = lines.index(stray)
    abort_with("#{name}: línea especial esperada no encontrada verbatim: #{stray.inspect}") unless stray_idx
    removed_indices << stray_idx
  end
  removed_indices.sort!

  kept_lines = lines.each_with_index.reject { |_, i| removed_indices.include?(i) }.map(&:first)
  new_body = kept_lines.join.gsub(/\n{3,}/, "\n\n")

  if new_body.include?("ALJO Control Level 1B Altius") || new_body.include?("PIPELINE_INJECTED")
    abort_with("#{name}: queda contaminación residual tras la remoción propuesta — NO es candidato seguro")
  end

  {
    file: name,
    contaminated: true,
    matches_plan_literal_regex: lines.any? { |l| l.match?(PLAN_LITERAL_REGEX) },
    removed_line_count: removed_indices.size,
    removed_lines: removed_indices.map { |i| lines[i] },
    old_body: body,
    new_body: new_body,
    old_sha256: Digest::SHA256.hexdigest(body),
    new_sha256: Digest::SHA256.hexdigest(new_body)
  }
end

# --- 1. Nombres de archivo esperados (de la copia de referencia local) ---

reference_files = Dir.glob("#{REFERENCE_BODY_DIR}/chunk_*.txt").reject { |f| f.include?(".metadata.json") }
unless reference_files.size == EXPECTED_CHUNK_COUNT
  abort_with("se esperaban #{EXPECTED_CHUNK_COUNT} cuerpos de referencia en #{REFERENCE_BODY_DIR}, hay #{reference_files.size}")
end
chunk_names = reference_files.map { |f| File.basename(f) }.sort_by { |n| n[/chunk_(\d+)\.txt/, 1].to_i }

# --- 2. Análisis: sobre la referencia local (diagnóstico) o en vivo (real) ---

s3 = REAL_MODE ? S3DocumentsService.new : nil

records = chunk_names.map do |name|
  body = if REAL_MODE
    live = s3.download("#{CHUNK_PREFIX}/#{name}")
    abort_with("#{name}: descarga en vivo vacía o falló") if live.blank?
    live.dup.force_encoding(Encoding::UTF_8)
  else
    File.binread(REFERENCE_BODY_DIR.join(name)).force_encoding(Encoding::UTF_8)
  end
  analyze(name, body)
end

contaminated = records.select { |r| r[:contaminated] }
plan_regex_hits = contaminated.select { |r| r[:matches_plan_literal_regex] }

puts "=" * 80
puts "Fase 3 N8 — #{REAL_MODE ? 'MODO REAL (cuerpos en vivo)' : 'diagnóstico (copia de referencia local)'} (2026-08-04)"
puts "=" * 80
puts "Cuerpos totales:                          #{records.size}"
puts "Contaminados (ALJO en el cuerpo):         #{contaminated.size}"
puts "Coinciden con el regex EXACTO del plan:   #{plan_regex_hits.size} (#{plan_regex_hits.pluck(:file).join(', ')})"
puts "Candidatos seguros bajo diseño de bloque: #{contaminated.size} (cero residuo verificado)"

report = records.map { |r| r.except(:old_body, :new_body) }
File.write(OUTPUT_DIR.join("n8_fase3_diagnostic_2026-08-04.json"), JSON.pretty_generate(report))
puts
puts "Reporte completo: #{OUTPUT_DIR.join('n8_fase3_diagnostic_2026-08-04.json')}"

exit 0 unless REAL_MODE

# --- 3. MODO REAL — Decisión humana #10 resuelta (Alcance A, 2026-08-04) ---
puts
puts "=" * 80
puts "MODO REAL — mutando bulk_chunks/1/#{DOCUMENT_ID}"
puts "=" * 80

stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
backup_prefix = "chunk_body_backups/1/#{DOCUMENT_ID}/#{stamp}_ciclo5_fase3"
local_backup  = OUTPUT_DIR.join("prod_backup_#{stamp}")
FileUtils.mkdir_p(local_backup)

puts "Respaldando los #{records.size} cuerpos vivos (S3 + local), tal como se descargaron recién…"
manifest = records.map do |r|
  File.binwrite(local_backup.join(r[:file]), r[:old_body])
  abort_with("backup upload falló para #{r[:file]}") unless s3.upload_binary("#{backup_prefix}/#{r[:file]}", r[:old_body], "text/plain; charset=utf-8")
  { "key" => "#{CHUNK_PREFIX}/#{r[:file]}", "sha256_before" => r[:old_sha256] || Digest::SHA256.hexdigest(r[:old_body]), "sha256_after" => r[:new_sha256] || Digest::SHA256.hexdigest(r[:old_body]) }
end
manifest_json = JSON.pretty_generate("stamp" => stamp, "bucket" => s3.bucket_name, "backup_prefix" => backup_prefix, "objects" => manifest)
File.write(local_backup.join("HASHES.json"), manifest_json)
s3.upload_binary("#{backup_prefix}/HASHES.json", manifest_json, "application/json")
puts "  Respaldo: s3://#{s3.bucket_name}/#{backup_prefix} y #{local_backup}"
puts "  (S3 tiene versioning habilitado en PROD — respaldo adicional más allá de este backup explícito.)"

puts "Escribiendo #{contaminated.size} cuerpos parcheados (invalidación de caché automática vía upload_text)…"
contaminated.each do |r|
  key = "#{CHUNK_PREFIX}/#{r[:file]}"
  abort_with("upload falló para #{r[:file]}") unless s3.upload_text(key, r[:new_body])
end

puts "Verificando post-escritura…"
contaminated.each do |r|
  key = "#{CHUNK_PREFIX}/#{r[:file]}"
  actual = s3.download(key)
  actual_sha = Digest::SHA256.hexdigest(actual.dup.force_encoding(Encoding::UTF_8))
  unless actual_sha == r[:new_sha256]
    abort_with("#{r[:file]} no coincide tras la escritura — restaurar desde s3://#{s3.bucket_name}/#{backup_prefix} (o la versión anterior de S3 versioning)")
  end
end
puts "  OK: #{contaminated.size}/#{contaminated.size} verificados."

puts
puts "Disparando resync del KB (BulkKbSyncService)…"
sync_result = BulkKbSyncService.new.sync!(uploaded_filenames: [ "SEGURIDADES 1.1-1.pdf" ], locale: "es")
abort_with("KB sync did not start") unless sync_result
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

abort_with("KB ingestion job ended with status #{status}") unless status == "COMPLETE"

# La invalidación de caché de la Fase 1 ya corrió automáticamente: cada
# `s3.upload_text` de arriba invocó `Rag::SectionNeighborExpander.invalidate!`
# para el prefijo (ver S3DocumentsService#upload_text / AGENTS.md, "Chunk
# Repair Cache Invalidation") — no hace falta ninguna llamada explícita más.

result = {
  "stamp" => stamp,
  "job_id" => sync_result[:job_id],
  "kb_id" => sync_result[:kb_id],
  "data_source_id" => sync_result[:data_source_id],
  "status" => status,
  "patched_chunks" => contaminated.size,
  "backup_prefix" => backup_prefix
}
File.write(OUTPUT_DIR.join("n8_fase3_real_run_result_2026-08-04.json"), JSON.pretty_generate(result))

puts "\nRESULT: OK — #{contaminated.size} cuerpos parcheados (Alcance A, bloque completo), KB sync COMPLETE, job_id=#{sync_result[:job_id]}"
