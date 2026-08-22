# frozen_string_literal: true

# Corta los PDFs que superan ZipExtractionService::MAX_FILE_BYTES en partes por
# rango de páginas y, opcionalmente, arma el ZIP de ingesta con ellas.
#
# El tope de 50 MB por entrada no salta el archivo: ZipExtractionService lanza
# Error y aborta el ZIP completo, así que estos PDFs quedaron fuera de los seis
# ZIPs del alcance.
#
# Se corta por rangos y no en páginas sueltas (PdfPageSplitterService#each_page)
# para que cada parte siga siendo un documento: un asset por página partiría
# cualquier procedimiento que cruce de página y multiplicaría las llamadas del
# PageRelevanceFilter, que agrupa ventanas de 20 páginas y se paga.
#
# Uso:
#   bin/rails runner script/split_oversized_pdfs.rb "/ruta/a.pdf" "/ruta/b.pdf"
#
# Env:
#   SPLIT_OUT_DIR  destino de las partes (default tmp/gonzalo_split)
#   SPLIT_MAX_MB   tope por parte (default 45, con margen bajo el 50 del extractor)
#   SPLIT_ZIP      si se indica, arma ese ZIP con todas las partes y lo verifica

require "digest"
require "fileutils"
require "zip"

paths = ARGV.dup
abort("Uso: bin/rails runner script/split_oversized_pdfs.rb <pdf> [<pdf>...]") if paths.empty?

out_dir   = ENV["SPLIT_OUT_DIR"].presence || "tmp/gonzalo_split"
max_mb    = (ENV["SPLIT_MAX_MB"].presence || 45).to_i
max_bytes = max_mb * 1024 * 1024

if max_bytes > ZipExtractionService::MAX_FILE_BYTES
  abort("SPLIT_MAX_MB=#{max_mb} supera ZipExtractionService::MAX_FILE_BYTES")
end

FileUtils.mkdir_p(out_dir)
produced = []

paths.each do |path|
  abort("No existe: #{path}") unless File.file?(path)

  binary   = File.binread(path)
  splitter = PdfPageSplitterService.new(binary)
  stem     = File.basename(path, ".*").strip
  pages    = splitter.page_count
  abort("HexaPDF no puede leer #{path}") if pages.zero?

  puts format("%s — %.1f MB, %d págs", File.basename(path), binary.bytesize / 1e6, pages)

  parts = []
  splitter.each_part(max_bytes: max_bytes) do |part|
    name = "#{stem} (p#{part.first_page}-#{part.last_page}).pdf"
    dest = File.join(out_dir, name)
    File.binwrite(dest, part.binary)

    parts << {
      name:   name,
      path:   dest,
      pages:  part.page_count,
      bytes:  part.byte_size,
      sha256: Digest::SHA256.hexdigest(part.binary)
    }
    puts format("  → %s — %.1f MB, %d págs", name, part.byte_size / 1e6, part.page_count)
  end

  # Sin esto, una página perdida en el corte sólo se notaría como material que
  # nunca aparece en retrieval, mucho después de pagarlo.
  covered = parts.sum { |part| part[:pages] }
  abort("#{File.basename(path)}: las partes cubren #{covered} págs de #{pages}") unless covered == pages

  produced.concat(parts)
end

# Las claves S3 del original son bulk_uploads/<account>/<fecha>/<basename>, así
# que dos partes con el mismo basename se pisarían.
repeated = produced.map { |part| part[:name] }.tally.select { |_, count| count > 1 }.keys
abort("Basenames repetidos: #{repeated.join(', ')}") if repeated.any?

puts
puts format("TOTAL %d partes, %d págs, %.1f MB en %s",
            produced.size, produced.sum { |p| p[:pages] }, produced.sum { |p| p[:bytes] } / 1e6, out_dir)

zip_path = ENV["SPLIT_ZIP"].presence
exit(0) unless zip_path

FileUtils.mkdir_p(File.dirname(zip_path))
File.delete(zip_path) if File.exist?(zip_path)

Zip::OutputStream.open(zip_path) do |zos|
  produced.each do |part|
    zos.put_next_entry(part[:name])
    zos.write(File.binread(part[:path]))
  end
end

# Releer con el extractor real es lo único que prueba que ninguna entrada dispara
# el tope por archivo, el guard de bomba o una detección de MIME inesperada.
# Barato comparado con descubrirlo cuando el job ya corre en producción.
seen = []
begin
  ZipExtractionService.new(zip_path).each_entry do |entry|
    unless entry[:content_type] == "application/pdf"
      abort("#{entry[:filename]} detectado como #{entry[:content_type]}")
    end
    seen << entry[:filename]
  end
rescue ZipExtractionService::Error => e
  abort("el extractor rechaza #{zip_path}: #{e.message}")
end

abort("el extractor ve #{seen.size} entradas de #{produced.size}") unless seen.size == produced.size

puts format("ZIP %s — %.1f MB, %d entradas verificadas con el extractor",
            zip_path, File.size(zip_path) / 1e6, seen.size)
puts "sha256 #{Digest::SHA256.file(zip_path).hexdigest}"
