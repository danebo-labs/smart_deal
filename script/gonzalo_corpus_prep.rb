# frozen_string_literal: true

# Prepara el corpus de manuales de Gonzalo para la ingesta bulk: inventario,
# presupuesto de créditos Anthropic y armado de los ZIPs.
#
# Cuenta páginas con PdfPageSplitterService (HexaPDF), el mismo motor que usa el
# pipeline de ingesta, para que el presupuesto salga del mismo número que después
# se factura. Un PDF que HexaPDF no puede abrir cuenta 0 páginas y se reporta:
# el pipeline tampoco podría procesarlo.
#
# Aplica los guardrails reales de ZipExtractionService en vez de replicarlos:
#   - MAX_FILE_BYTES: una entrada que lo supera NO se salta, aborta el ZIP entero,
#     así que esos PDFs quedan excluidos y se listan.
#   - MAX_TOTAL_BYTES: tope por ZIP. Los bins se arman muy por debajo, porque un
#     ZIP que falla a mitad ya consumió créditos por las páginas procesadas.
#
# Hace:
#   1. Recorre el corpus y recoge SHA-256, bytes y páginas de cada PDF.
#   2. Deduplica por contenido (el corpus trae carpetas espejo "xxx (1)").
#   3. Reporta exclusiones: sobredimensionados, ilegibles y colisiones de basename
#      (sanitize_filename aplasta la ruta y la clave S3 del original es
#      bulk_uploads/<account_id>/<fecha>/<basename>).
#   4. Imprime páginas y coste por marca.
#   5. Opcional: arma un ZIP de validación barato + los ZIPs de producción.
#
# Uso:
#   GONZALO_MANUALS_DIR=~/Documents/.../Manuales\ Gonzalo \
#     bin/rails runner script/gonzalo_corpus_prep.rb
#
# Opcional:
#   GONZALO_VENDORS=KONE,TKE        # limita el alcance a esas carpetas raíz
#   GONZALO_ZIPS_DIR=tmp/zips       # además de reportar, escribe los ZIPs
#   GONZALO_REPORT=tmp/scope.json   # vuelca el detalle por archivo
#   GONZALO_BIN_MB=140              # tamaño objetivo por ZIP sin comprimir

require "digest"
require "zip"

# US$0.027/página en modo batch, conciliado contra factura (US$5.32 por un manual
# de 200 páginas). El buffer cubre el filtro Haiku y los reintentos por página.
PRICE_PER_PAGE = 0.027
BUFFER = 1.3

root = ENV["GONZALO_MANUALS_DIR"].presence or
  abort("Set GONZALO_MANUALS_DIR to the manuals root directory")
root = File.expand_path(root)
abort("Not a directory: #{root}") unless File.directory?(root)

vendors  = ENV["GONZALO_VENDORS"].to_s.split(",").map(&:strip).reject(&:empty?)
zips_dir = ENV["GONZALO_ZIPS_DIR"].presence
bin_cap  = (ENV["GONZALO_BIN_MB"].presence || 140).to_i * 1024 * 1024

if bin_cap > ZipExtractionService::MAX_TOTAL_BYTES
  abort("GONZALO_BIN_MB exceeds ZipExtractionService::MAX_TOTAL_BYTES")
end

# macOS entrega los nombres en NFD; normalizamos sólo para comparar.
def nfc(str) = str.unicode_normalize(:nfc)

search_roots = vendors.empty? ? [ root ] : vendors.map { |v| File.join(root, v) }
search_roots.each { |dir| abort("Missing vendor directory: #{dir}") unless File.directory?(dir) }

files = []
search_roots.each do |dir|
  Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
    next unless File.file?(path) && !File.symlink?(path)
    next unless File.extname(path).downcase == ".pdf"
    next if File.basename(path).start_with?(".")

    binary = File.binread(path)
    rel    = path.delete_prefix("#{root}/")
    files << {
      vendor:   rel.split(File::SEPARATOR).first,
      rel:      rel,
      path:     path,
      basename: File.basename(path),
      bytes:    binary.bytesize,
      sha256:   Digest::SHA256.hexdigest(binary),
      pages:    PdfPageSplitterService.new(binary).page_count
    }
    print "." if (files.size % 25).zero?
  end
end
puts
abort("No PDFs found under #{search_roots.join(', ')}") if files.empty?

# Un representante por contenido: la ruta más corta suele ser el original y no la
# copia en la carpeta espejo.
unique = files.group_by { |f| f[:sha256] }
              .values
              .map { |group| group.min_by { |f| [ f[:rel].length, f[:rel] ] } }
              .sort_by { |f| f[:rel] }

oversized  = unique.select { |f| f[:bytes] > ZipExtractionService::MAX_FILE_BYTES }
unreadable = unique.select { |f| f[:pages].zero? }
ingestible = unique - oversized - unreadable

collisions = ingestible.group_by { |f| nfc(f[:basename]) }.select { |_, g| g.size > 1 }

pages  = ingestible.sum { |f| f[:pages] }
budget = pages * PRICE_PER_PAGE * BUFFER

puts "Corpus: #{root}"
puts "Alcance: #{vendors.empty? ? 'todas las marcas' : vendors.join(', ')}"
puts
puts format("%-16s %6s %8s %9s", "marca", "pdfs", "págs", "USD")
by_vendor = ingestible.group_by { |f| f[:vendor] }
by_vendor.sort_by { |_, g| -g.sum { |f| f[:pages] } }.each do |vendor, group|
  vendor_pages = group.sum { |f| f[:pages] }
  puts format("%-16s %6d %8d %9.0f", vendor.slice(0, 16), group.size,
              vendor_pages, vendor_pages * PRICE_PER_PAGE * BUFFER)
end
puts format("%-16s %6d %8d %9.2f", "TOTAL", ingestible.size, pages, budget)
puts

puts "PDFs en disco:            #{files.size}"
puts "Duplicados exactos:       #{files.size - unique.size}"
puts "Excluidos por tamaño:     #{oversized.size} (tope #{ZipExtractionService::MAX_FILE_BYTES / 1024 / 1024} MB por entrada)"
oversized.each { |f| puts format("  - %s (%.1f MB, %d págs)", f[:rel], f[:bytes] / 1e6, f[:pages]) }
puts "Ilegibles para HexaPDF:   #{unreadable.size}"
unreadable.each { |f| puts "  - #{f[:rel]}" }
puts "Colisiones de basename:   #{collisions.size}"
collisions.each do |name, group|
  puts "  - #{name}"
  group.each { |f| puts "      #{f[:rel]}" }
end

if ENV["GONZALO_REPORT"].present?
  FileUtils.mkdir_p(File.dirname(ENV["GONZALO_REPORT"]))
  File.write(ENV["GONZALO_REPORT"], JSON.pretty_generate(
    root: root, vendors: vendors, pages: pages, budget_usd: budget.round(2),
    oversized: oversized.map { |f| f.slice(:rel, :bytes, :pages) },
    unreadable: unreadable.pluck(:rel),
    basename_collisions: collisions.transform_values { |g| g.map { |f| f[:rel] } },
    files: ingestible.map { |f| f.slice(:vendor, :rel, :basename, :bytes, :sha256, :pages) }
  ))
  puts "\nReporte: #{ENV['GONZALO_REPORT']}"
end

exit(0) if zips_dir.blank?
abort("No se arman ZIPs: hay colisiones de basename sin resolver") if collisions.any?

# Muestra de validación: los PDFs cortos más livianos, repartidos en round-robin
# entre marcas para que ninguna quede sin representar, y así probar el pipeline
# end-to-end (citas, field_records) gastando poco más de un dólar.
SAMPLE_SIZE = 4
candidates = ingestible.select { |f| f[:pages].between?(3, 40) }
                       .group_by { |f| f[:vendor] }
                       .values
                       .map { |group| group.sort_by { |f| f[:bytes] } }

sample = []
round  = 0
while sample.size < SAMPLE_SIZE && candidates.any? { |group| group[round] }
  candidates.each do |group|
    break if sample.size >= SAMPLE_SIZE

    file = group[round]
    sample << file if file
  end
  round += 1
end

remaining = ingestible - sample

bins = []
remaining.sort_by { |f| -f[:bytes] }.each do |file|
  target = bins.find { |b| b[:bytes] + file[:bytes] <= bin_cap }
  target ||= { files: [], bytes: 0 }.tap { |b| bins << b }
  target[:files] << file
  target[:bytes] += file[:bytes]
end
bins.each { |b| b[:files].sort_by! { |f| f[:rel] } }
bins.sort_by! { |b| b[:files].first[:rel] }

FileUtils.mkdir_p(zips_dir)
jobs = [ [ "00_validacion.zip", sample ] ]
jobs += bins.each_with_index.map { |b, i| [ format("%02d_ingesta.zip", i + 1), b[:files] ] }

# Relee el ZIP recién escrito con el extractor real del pipeline: confirma que
# ninguna entrada dispara el guard de bomba ni el tope por archivo, que todas se
# detectan como PDF y que ninguna se salta. Barato comparado con descubrirlo
# cuando el job ya está corriendo en producción.
def verify_with_extractor!(path)
  extractor = ZipExtractionService.new(path)
  seen = []
  extractor.each_entry do |entry|
    unless entry[:content_type] == "application/pdf"
      abort("#{File.basename(path)}: #{entry[:filename]} detectado como #{entry[:content_type]}")
    end
    seen << entry[:filename]
  end

  skipped = extractor.skipped_entries
  abort("#{File.basename(path)}: entradas saltadas — #{skipped.pluck(:filename).join(', ')}") if skipped.any?

  repeated = seen.tally.select { |_, count| count > 1 }.keys
  abort("#{File.basename(path)}: basename repetido tras aplastar rutas — #{repeated.join(', ')}") if repeated.any?

  seen.size
rescue ZipExtractionService::Error => e
  abort("#{File.basename(path)}: el extractor lo rechaza — #{e.message}")
end

manifest = jobs.map do |name, entries|
  path = File.join(zips_dir, name)
  Zip::OutputStream.open(path) do |zos|
    entries.each do |file|
      zos.put_next_entry(file[:rel])
      zos.write(File.binread(file[:path]))
    end
  end

  verified = verify_with_extractor!(path)
  abort("#{name}: el extractor ve #{verified} entradas y esperábamos #{entries.size}") if verified != entries.size

  zip_pages = entries.sum { |f| f[:pages] }
  raw_bytes = entries.sum { |f| f[:bytes] }
  puts format("%-22s %3d pdfs %6d págs %7.1f MB crudo %7.1f MB zip  ~$%-7.2f extractor OK",
              name, entries.size, zip_pages, raw_bytes / 1e6,
              File.size(path) / 1e6, zip_pages * PRICE_PER_PAGE * BUFFER)

  {
    zip: name, pdfs: entries.size, pages: zip_pages,
    uncompressed_bytes: raw_bytes, zip_bytes: File.size(path),
    est_usd_with_buffer: (zip_pages * PRICE_PER_PAGE * BUFFER).round(2),
    files: entries.map { |f| f.slice(:rel, :pages, :sha256) }
  }
end

File.write(File.join(zips_dir, "manifest.json"), JSON.pretty_generate(manifest))
puts
puts format("TOTAL %d pdfs, %d págs, ~$%.2f con buffer",
            manifest.sum { |m| m[:pdfs] }, manifest.sum { |m| m[:pages] },
            manifest.sum { |m| m[:est_usd_with_buffer] })
puts "Manifiesto: #{File.join(zips_dir, 'manifest.json')}"
