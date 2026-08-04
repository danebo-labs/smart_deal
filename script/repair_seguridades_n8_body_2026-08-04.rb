# frozen_string_literal: true

# Fase 3 de docs/rag/plan_ciclo5_resolucion_decision9_2026-08-04.md — parche
# determinístico SIN LLM de los cuerpos de chunk contaminados por N8 (identidad
# "ALJO Control Level 1B Altius" incrustada en páginas que no son de ALJO).
#
# ESTADO (2026-08-04): la hipótesis de LÍNEA ÚNICA del borrador del plan quedó
# FALSIFICADA contra los 97 cuerpos verificados (ver plan, Estado Fase 3 y
# "Decisión humana #10"). El regex literal del plan
# (`\*\*Document:\*\* ALJO Control Level 1B Altius \| Page \d+ \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED.*`)
# sólo coincide EXACTO con 1 de 96 cuerpos contaminados (chunk_43) — el modelo
# de visión nunca siguió un template fijo al obedecer la instrucción retirada
# en la Fase 2 ("Each section title must appear inside the chunk after the
# **Document:** header"), así que produjo 11 formas distintas de un bloque de
# 1-4 líneas, más 2 casos de contaminación FUERA de ese bloque (chunk_0:
# filas de tabla en la sección S0; chunk_36: línea suelta en prosa, línea 75).
#
# El diseño de detección de BLOQUE + 2 casos especiales de abajo SÍ cubre los
# 96 cuerpos con CERO residuo verificado — ver
# tmp/ciclo5_fase3_2026-08-04/n8_fase3_diagnostic_2026-08-04.json (generado
# por este mismo script) y el hallazgo H10 / "Decisión humana #10" en el plan.
# Pero remover un bloque de hasta 4 líneas (incluye **Section:**/**Page:**,
# que sí llevan info real de página/sección) es un alcance MÁS AMPLIO que el
# "sustituir una única línea" que autorizó la restricción 2 del plan — esta
# sesión NO decide unilateralmente ese alcance. Por eso el modo real permanece
# deshabilitado: este script es SOLO DIAGNÓSTICO (lee la copia de referencia
# local, no llama a S3 ni a Bedrock) hasta que el dueño resuelva la Decisión
# humana #10 (elegir alcance A: bloque completo [recomendado] vs. B: preservar
# líneas **Section:**/**Page:** sueltas) y autorice explícitamente ejecutar
# contra producción con ese alcance.
#
# Uso (el único modo soportado hoy — sólo lectura, sin red):
#   bin/rails runner script/repair_seguridades_n8_body_2026-08-04.rb

require "json"
require "digest"
require "fileutils"

DOCUMENT_ID  = "b61f5d54-ff42-414a-97b7-01682d16f4b5"
CHUNK_PREFIX = "bulk_chunks/1/#{DOCUMENT_ID}" # usado por la Fase 3 real, no por este diagnóstico

REFERENCE_BODY_DIR = Rails.root.join("tmp/seguridades_chunks_2026-07-28")
OUTPUT_DIR = Rails.root.join("tmp/ciclo5_fase3_2026-08-04")
FileUtils.mkdir_p(OUTPUT_DIR)

# Forma que el plan asumía "regular y greppeable" en el 96/97 — en la práctica
# sólo coincide con chunk_43 (ver diagnóstico de esta sesión).
PLAN_LITERAL_REGEX = /\*\*Document:\*\* ALJO Control Level 1B Altius \| Page \d+ \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED.*/

# Detección de bloque real: empieza en la línea **Document:** y se extiende
# mientras las líneas siguientes sean continuaciones conocidas del mismo
# encabezado de identidad inyectado por el prompt viejo.
DOC_LINE = /\A\*\*Document:\*\*/
BLOCK_CONTINUATION = /\A(\*\*Section:\*\*|\*\*Page:\*\*|ORIGINAL_FILE_NAME:|NORMALIZED_FILE_NAME:|SOURCE_URI:)/

# Casos especiales verificados manualmente contra la copia de referencia
# (2026-08-04): contaminación FUERA del bloque contiguo de identidad. Sin
# estos dos, quedaría residuo tras remover sólo el bloque (verificado: el
# safety-check de esta sesión aborta si queda cualquier residuo).
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

chunk_files = Dir.glob("#{REFERENCE_BODY_DIR}/chunk_*.txt").reject { |f| f.include?(".metadata.json") }
unless chunk_files.size == 97
  abort_with("se esperaban 97 cuerpos de referencia en #{REFERENCE_BODY_DIR}, hay #{chunk_files.size}")
end
chunk_files = chunk_files.sort_by { |f| f[/chunk_(\d+)\.txt/, 1].to_i }

records = []
chunk_files.each do |path|
  name = File.basename(path)
  body = File.binread(path).force_encoding(Encoding::UTF_8)
  abort_with("#{name}: referencia no es UTF-8 válido") unless body.valid_encoding?

  lines = body.lines
  doc_idx = lines.index { |l| l.match?(DOC_LINE) }

  unless doc_idx
    records << { file: name, contaminated: false, reason: "no **Document:** line" }
    next
  end

  unless lines[doc_idx].include?("ALJO Control Level 1B Altius")
    # chunk_90: "**Document:** PIPELINE_INJECTED" (sin nombre ALJO) — el único
    # cuerpo limpio de contaminación de IDENTIDAD; el plan pide explícitamente
    # no tocarlo, y esta rama nunca lo marca como contaminado.
    records << { file: name, contaminated: false, reason: "identity line present but not ALJO-named (chunk_90 case)" }
    next
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

  records << {
    file: name,
    contaminated: true,
    matches_plan_literal_regex: lines.any? { |l| l.match?(PLAN_LITERAL_REGEX) },
    removed_line_count: removed_indices.size,
    removed_lines: removed_indices.map { |i| lines[i] },
    old_sha256: Digest::SHA256.hexdigest(body),
    proposed_new_sha256_if_scope_full_block: Digest::SHA256.hexdigest(new_body)
  }
end

contaminated = records.select { |r| r[:contaminated] }
plan_regex_hits = contaminated.select { |r| r[:matches_plan_literal_regex] }

puts "=" * 80
puts "Fase 3 N8 — diagnóstico (2026-08-04) — SOLO LECTURA, cero llamadas de red"
puts "=" * 80
puts "Cuerpos totales:                          #{records.size}"
puts "Contaminados (ALJO en el cuerpo):         #{contaminated.size}"
puts "Coinciden con el regex EXACTO del plan:   #{plan_regex_hits.size} (#{plan_regex_hits.pluck(:file).join(', ')})"
puts "Candidatos seguros bajo diseño de bloque: #{contaminated.size} (cero residuo verificado, ver JSON)"
puts
puts "CONCLUSION: hipotesis de linea unica del plan FALSIFICADA " \
     "(#{plan_regex_hits.size}/#{contaminated.size} coincide exacto). El diseno de " \
     "bloque de esta sesion cubre el 100% sin residuo, pero NO se ejecuta " \
     "contra S3/Bedrock aqui -- ver Decision humana #10 en el plan."

File.write(OUTPUT_DIR.join("n8_fase3_diagnostic_2026-08-04.json"), JSON.pretty_generate(records))
puts
puts "Reporte completo: #{OUTPUT_DIR.join('n8_fase3_diagnostic_2026-08-04.json')}"

# --- MODO REAL: deshabilitado a propósito ---
# El plan autorizó (restricción 2) "sustitución de texto por chunk" asumiendo
# que "la línea contaminante ES exactamente esa única línea". Esta sesión
# probó que esa forma no existe en 95/96 cuerpos: la contaminación real es un
# bloque de 1-4 líneas en 11 formas, más 2 casos fuera del bloque. Ejecutar un
# parche de alcance más amplio que el literalmente autorizado, sin que el
# dueño lo revise, no es una decisión que le corresponda a esta sesión —
# Protocolo de plan vivo, item 4: "si un hallazgo contradice una restricción
# ... no lo ejecutes, escálalo". Ningún camino de este script escribe a S3 ni
# dispara `start-ingestion-job`.
if ENV["RAG_CHUNK_PATCH_CONFIRM"] == "1"
  abort_with(
    "Modo real deshabilitado: Decision humana #10 pendiente (ver plan, seccion " \
    "'Decision humana #10'). Este script es solo diagnostico hasta que el " \
    "dueno elija el alcance de remocion (bloque completo recomendado vs. " \
    "preservar **Section:**/**Page:**) y autorice explicitamente ejecutar " \
    "contra produccion con ese alcance."
  )
end
