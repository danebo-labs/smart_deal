# frozen_string_literal: true

# Fase 2, punto 1 de docs/RAG_PRECISION_V2_PLAN_2026-07-29.md ("Generar un manifiesto
# de auditoría, sin escribir, que compare cada chunk con: encabezado visible; página;
# fabricante/modelo/placa; sección padre; página anterior/siguiente de la misma
# sección"), fila asignada a Sonnet en la revisión ("Manifiesto de auditoría de
# sidecars (solo lectura)").
#
# Solo lectura: no llama a Bedrock, S3 ni Rails; no escribe nada salvo el propio
# manifiesto de salida. Lee los 97 pares chunk/.metadata.json ya descargados de
# producción el 2026-07-29 (docs/RAG_PRODUCTION_TRACE_2026-07-29.md, "Copia lectora de
# chunks/sidecars"), en vez de repetir la lectura contra S3/KB.
#
# No existe ningún campo `manufacturer`/`controller_model`/`board_model` en el sidecar
# (confirmado en docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md §F1): el único
# candidato de identidad estructural es `section_identity`, hoy ausente en los 97
# (contrato `field_records_v5`). Por eso "fabricante/modelo/placa" se audita comparando
# el `canonical_name` plano del sidecar contra el encabezado y los alias realmente
# impresos en cada chunk, sin introducir ninguna lista de fabricantes en este script.
#
# Uso:
#   ruby script/audit_seguridades_sidecar_manifest_2026-07-29.rb \
#     [directorio_de_chunks] [ruta_de_salida.json]
#
# Por defecto lee tmp/pdfs/seguridades_audit/production_chunks y escribe
# tmp/rag_seguridades_sidecar_manifest_2026-07-29.json.

require "json"
require "set"

CHUNKS_DIR = ARGV[0] || File.join(__dir__, "..", "tmp", "pdfs", "seguridades_audit", "production_chunks")
OUTPUT_PATH = ARGV[1] || File.join(__dir__, "..", "tmp", "rag_seguridades_sidecar_manifest_2026-07-29.json")

def fold_for_search(text)
  text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").upcase
end

def extract_heading(body)
  body.each_line do |line|
    stripped = line.strip
    return stripped if stripped.start_with?("## ")
  end
  body.each_line do |line|
    stripped = line.strip
    return stripped if stripped.start_with?("**Document:**")
  end
  body.lines.map(&:strip).find { |line| !line.empty? }
end

def extract_field(body, label)
  match = body.match(/^\*\*#{Regexp.escape(label)}:\*\*\s*(.+)$/)
  match && match[1].strip
end

def extract_search_aliases(body)
  match = body.match(/^\[SEARCH_ALIASES:\s*(.+?)\]\s*$/)
  return [] unless match

  match[1].split(",").map(&:strip).reject(&:empty?)
end

def body_page_number(body)
  page_field = extract_field(body, "Page")
  return nil unless page_field

  digits = page_field[/\d+/]
  digits && digits.to_i
end

chunk_paths = Dir.glob(File.join(CHUNKS_DIR, "chunk_*.txt")).reject { |p| p.end_with?(".metadata.json") }
raise "No chunks found under #{CHUNKS_DIR}" if chunk_paths.empty?

records = chunk_paths.map do |txt_path|
  meta_path = "#{txt_path}.metadata.json"
  raise "Missing sidecar for #{txt_path}" unless File.exist?(meta_path)

  body = File.read(txt_path, encoding: "utf-8")
  meta = JSON.parse(File.read(meta_path, encoding: "utf-8")).fetch("metadataAttributes")

  canonical_name = meta["canonical_name"]
  {
    "chunk_file" => File.basename(txt_path),
    "page_number" => meta["page_number"],
    "body_page_number" => body_page_number(body),
    "visible_heading" => extract_heading(body),
    "section_line" => extract_field(body, "Section"),
    "canonical_name" => canonical_name,
    "section_identity" => meta["section_identity"],
    "search_aliases" => extract_search_aliases(body).first(5),
    "canonical_name_visible_in_body" => canonical_name && fold_for_search(body).include?(fold_for_search(canonical_name))
  }
end

records.sort_by! { |r| r["page_number"] }

records.each_with_index do |record, index|
  prev_record = index.positive? ? records[index - 1] : nil
  next_record = index < records.size - 1 ? records[index + 1] : nil

  record["prev_page_number"] = prev_record && prev_record["page_number"]
  record["prev_visible_heading"] = prev_record && prev_record["visible_heading"]
  record["next_page_number"] = next_record && next_record["page_number"]
  record["next_visible_heading"] = next_record && next_record["visible_heading"]
  record["heading_changed_vs_prev"] = prev_record.nil? || prev_record["visible_heading"] != record["visible_heading"]

  flags = []
  flags << "section_identity_missing" if record["section_identity"].nil?
  flags << "no_section_line" if record["section_line"].nil?
  flags << "no_body_page_number" if record["body_page_number"].nil?
  if record["body_page_number"] && record["body_page_number"] != record["page_number"]
    flags << "body_page_mismatch"
  end
  flags << "canonical_name_not_visible_in_body" unless record["canonical_name_visible_in_body"]
  record["flags"] = flags
end

# rubocop:disable Rails/Pluck -- plain Ruby script, no ActiveSupport loaded
distinct_canonical_names = records.map { |r| r["canonical_name"] }.uniq
distinct_section_identities = records.map { |r| r["section_identity"] }.uniq
distinct_headings = records.map { |r| r["visible_heading"] }.uniq
# rubocop:enable Rails/Pluck

summary = {
  "total_chunks" => records.size,
  "distinct_canonical_name_count" => distinct_canonical_names.size,
  "distinct_canonical_names" => distinct_canonical_names,
  "distinct_section_identity_values" => distinct_section_identities,
  "distinct_visible_heading_count" => distinct_headings.size,
  "chunks_with_section_identity" => records.count { |r| !r["section_identity"].nil? },
  "chunks_with_section_line" => records.count { |r| !r["section_line"].nil? },
  "chunks_with_body_page_number" => records.count { |r| !r["body_page_number"].nil? },
  "chunks_with_body_page_mismatch" => records.count { |r| r["flags"].include?("body_page_mismatch") },
  "chunks_where_canonical_name_not_visible_in_body" => records.count { |r| r["flags"].include?("canonical_name_not_visible_in_body") },
  "heading_changes_vs_prev" => records.count { |r| r["heading_changed_vs_prev"] } - 1
}

manifest = {
  "generated_from" => CHUNKS_DIR,
  "source_note" => "Read-only local copy of the 97 real SEGURIDADES 1.1-1 sidecars fetched from production on 2026-07-29 (docs/RAG_PRODUCTION_TRACE_2026-07-29.md). No new S3/Bedrock/production call was made to produce this manifest.",
  "summary" => summary,
  "chunks" => records
}

File.write(OUTPUT_PATH, JSON.pretty_generate(manifest))
puts JSON.pretty_generate(summary)
puts "Manifest written to #{OUTPUT_PATH}"
