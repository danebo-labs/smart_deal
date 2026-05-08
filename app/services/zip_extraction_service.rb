# frozen_string_literal: true

require 'zip'
require 'digest'

# Streams entries out of a ZIP file with safety guardrails.
# Yields { filename:, binary:, content_type:, sha256: } for each allowed entry.
# Raises ZipExtractionService::Error on policy violations.
class ZipExtractionService
  class Error < StandardError; end

  ALLOWED_MIME_TYPES = %w[image/jpeg image/png application/pdf].freeze
  MAX_FILE_BYTES     = 50 * 1024 * 1024   # 50 MB per entry
  MAX_TOTAL_BYTES    = 500 * 1024 * 1024  # 500 MB total uncompressed
  MAX_RATIO          = 100                 # compression ratio cap (zip-bomb guard)

  def initialize(zip_path)
    @zip_path = zip_path
  end

  # Yields each valid entry as a hash. Skips directories and hidden files.
  # Raises Error for violations (bomb, oversized, bad MIME).
  def each_entry
    total_bytes = 0

    Zip::File.open(@zip_path) do |zip|
      zip.each do |entry|
        next if entry.directory?
        next if File.basename(entry.name).start_with?('.')

        compressed_size = entry.compressed_size
        uncompressed_size = entry.size

        if compressed_size > 0 && (uncompressed_size.to_f / compressed_size) > MAX_RATIO
          raise Error, "ZIP bomb detected: #{entry.name} has compression ratio #{(uncompressed_size.to_f / compressed_size).round(1)}×"
        end

        if uncompressed_size > MAX_FILE_BYTES
          raise Error, "File too large: #{entry.name} is #{(uncompressed_size / 1024.0 / 1024).round(1)} MB (limit 50 MB)"
        end

        total_bytes += uncompressed_size
        if total_bytes > MAX_TOTAL_BYTES
          raise Error, "ZIP total uncompressed size exceeds 500 MB limit"
        end

        binary = entry.get_input_stream.read
        mime   = detect_mime(binary, entry.name)

        unless ALLOWED_MIME_TYPES.include?(mime)
          raise Error, "Unsupported file type '#{mime}' for #{entry.name}. Allowed: #{ALLOWED_MIME_TYPES.join(', ')}"
        end

        yield({
          filename:     sanitize_filename(entry.name),
          binary:       binary,
          content_type: mime,
          sha256:       Digest::SHA256.hexdigest(binary)
        })
      end
    end
  end

  private

  JPEG_MAGIC = "\xFF\xD8\xFF".b
  PNG_MAGIC  = "\x89PNG\r\n\x1A\n".b
  PDF_MAGIC  = "%PDF".b

  # ZIP entry names without the UTF-8 flag come back as ASCII-8BIT.
  # Force UTF-8 interpretation; fall back to Windows-1252 (common on macOS/Windows zips) if invalid.
  def sanitize_filename(raw)
    name = raw.dup.force_encoding("UTF-8")
    unless name.valid_encoding?
      name = raw.encode("UTF-8", "Windows-1252", invalid: :replace, undef: :replace, replace: "_")
    end
    File.basename(name)
  end

  def detect_mime(binary, filename)
    header = binary.b[0, 8]

    return "image/jpeg"       if header.start_with?(JPEG_MAGIC)
    return "image/png"        if header.start_with?(PNG_MAGIC)
    return "application/pdf"  if header.start_with?(PDF_MAGIC)

    # Extension fallback when magic bytes are ambiguous
    case File.extname(filename).downcase
    when ".jpg", ".jpeg" then "image/jpeg"
    when ".png"          then "image/png"
    when ".pdf"          then "application/pdf"
    else "application/octet-stream"
    end
  end
end
