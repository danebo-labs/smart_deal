# frozen_string_literal: true

# Pre-flight de disco para un ZIP de ingesta: cuánto escribe en /tmp el troceado
# por páginas de cada documento, comparado con el espacio libre del host.
#
# Corre en local y no llama a ninguna API. Es la comprobación que le faltó a
# 04_ingesta: dos escaneos KONE de 515 páginas en el mismo ZIP pedían 8,9 GB
# contra 9,9 GB libres, y el segundo murió en su página 383 con "No space left on
# device" cuando el filtro de páginas ya estaba facturado.
#
# El reparto en ZIPs se hace por bytes de origen (script/gonzalo_corpus_prep.rb),
# y los bytes de origen NO predicen el disco: la extracción por página copia el
# árbol de recursos compartidos del PDF en cada página, así que 16 MB de origen
# pueden convertirse en 10,4 MB por página. Como predictor se equivoca por un
# factor de ~350.
#
# Uso:
#   bin/rails runner script/pdf_split_peak_audit.rb tmp/gonzalo_zips/01_ingesta.zip
#   bin/rails runner script/pdf_split_peak_audit.rb manual.pdf otro.pdf
#
# Env:
#   DISK_FREE_GB   espacio libre del host contra el que comparar (default 9)
#   SAFETY_RATIO   fracción del libre que un ZIP puede pedir (default 0.7)
#   SAMPLE_PAGES   mide sólo N páginas por documento y extrapola. Sirve para
#                  triar un corpus grande; NO para autorizar un ZIP ajustado.
#
# Sale con código 1 si algún ZIP pasa del presupuesto, para poder usarlo como
# puerta antes de subir a S3.

require "zip"

paths = ARGV.dup
abort("Uso: bin/rails runner script/pdf_split_peak_audit.rb <zip|pdf> [...]") if paths.empty?

free_bytes = (ENV["DISK_FREE_GB"].presence || 9).to_f * 1e9
ratio      = (ENV["SAFETY_RATIO"].presence || 0.7).to_f
sample     = ENV["SAMPLE_PAGES"].presence&.to_i
budget     = free_bytes * ratio

def documents_in(path)
  return [ [ File.basename(path), File.binread(path) ] ] unless File.extname(path).downcase == ".zip"

  [].tap do |entries|
    Zip::File.open(path) do |zip|
      zip.each do |entry|
        next if entry.directory? || File.extname(entry.name).downcase != ".pdf"

        entries << [ entry.name, entry.get_input_stream.read ]
      end
    end
  end
end

over_budget = false

paths.each do |path|
  abort("no existe #{path}") unless File.exist?(path)

  rows = documents_in(path).map do |name, binary|
    result = PdfSplitPeakEstimator.new(binary).call(sample: sample)
    [ name, result ]
  rescue PdfSplitPeakEstimator::Error => e
    warn("  #{name}: #{e.message}")
    nil
  end.compact

  total_peak  = rows.sum { |_, result| result.peak_bytes }
  total_pages = rows.sum { |_, result| result.page_count }

  puts "#{File.basename(path)} — #{rows.size} docs, #{total_pages} pags"
  rows.sort_by { |_, result| -result.peak_bytes }.first(10).each do |name, result|
    printf("  %-52s %s\n", File.basename(name)[0, 52], result)
  end

  printf(
    "  PICO DEL ZIP %.2f GB  presupuesto %.2f GB (%.0f%% de %.1f GB libres)  %s\n\n",
    total_peak / 1e9, budget / 1e9, ratio * 100, free_bytes / 1e9,
    total_peak > budget ? "PASADO DE PRESUPUESTO" : "cabe"
  )

  over_budget ||= total_peak > budget
end

if over_budget
  warn("Reparte los documentos pesados en ZIPs separados: se procesan de uno en uno y el pico es por ejecución.")
  exit 1
end
