# frozen_string_literal: true

require 'zip'
require 'digest'

# Streams entries out of a ZIP file with safety guardrails.
# Yields { filename:, binary:, content_type:, sha256: } for each allowed entry.
# Raises ZipExtractionService::Error on global policy violations (bomb, size).
# Per-file MIME/Office failures are accumulated in skipped_entries instead of raising.
class ZipExtractionService
  class Error < StandardError; end

  ALLOWED_MIME_TYPES = %w[image/jpeg image/png image/webp image/gif application/pdf].freeze
  OFFICE_EXTENSIONS  = FileMultimodalRouter::OFFICE_EXTENSIONS.freeze
  MAX_FILE_BYTES     = 50 * 1024 * 1024   # 50 MB per entry
  MAX_TOTAL_BYTES    = 500 * 1024 * 1024  # 500 MB total uncompressed
  MAX_RATIO          = 100                 # compression ratio cap (zip-bomb guard)

  def initialize(zip_path)
    @zip_path = zip_path
    @skipped  = []
  end

  # Entries skipped due to unsupported MIME or failed Office conversion.
  # Each element: { filename:, binary:, reason:, sha256: }
  # Only valid after each_entry has completed.
  def skipped_entries
    @skipped.freeze
  end

  # Yields each valid entry as a hash. Skips directories and hidden files.
  # Raises Error for global violations (bomb, oversized ZIP total).
  # Per-file MIME/Office issues accumulate in skipped_entries.
  def each_entry
    total_bytes = 0

    Zip::File.open(@zip_path) do |zip|
      zip.each do |entry|
        next if entry.directory?
        next if File.basename(entry.name).start_with?('.')

        compressed_size   = entry.compressed_size
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

        binary        = entry.get_input_stream.read
        ext           = File.extname(entry.name).downcase
        filename      = sanitize_filename(entry.name)
        office_origin = OFFICE_EXTENSIONS.include?(ext)

        if office_origin
          begin
            binary   = OfficeToPdfConverter.convert(binary, extension: ext)
            filename = "#{File.basename(filename, ext)}.pdf"
            mime     = "application/pdf"
          rescue OfficeToPdfConverter::Error => e
            record_skip(
              entry.name, binary,
              "bulk_uploads.office_conversion_failed",
              filename: entry.name, detail: e.message
            )
            next
          end
        else
          mime = detect_mime(binary, entry.name)
        end

        unless ALLOWED_MIME_TYPES.include?(mime)
          record_skip(
            entry.name, binary,
            "bulk_uploads.unsupported_file_type",
            mime: mime, filename: entry.name, allowed: ALLOWED_MIME_TYPES.join(", ")
          )
          next
        end

        yield({
          filename:      filename,
          binary:        binary,
          content_type:  mime,
          sha256:        Digest::SHA256.hexdigest(binary),
          office_origin: office_origin
        })
      end
    end
  end

  private

  def record_skip(entry_name, binary, reason_key, **reason_params)
    @skipped << {
      filename:      sanitize_filename(entry_name),
      binary:        binary,
      reason_key:    reason_key,
      reason_params: reason_params,
      sha256:        Digest::SHA256.hexdigest(binary)
    }
  end

  JPEG_MAGIC = "\xFF\xD8\xFF".b
  PNG_MAGIC  = "\x89PNG\r\n\x1A\n".b
  PDF_MAGIC  = "%PDF".b
  WEBP_RIFF  = "RIFF".b
  WEBP_TYPE  = "WEBP".b
  GIF_MAGIC  = "GIF".b

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
    header = binary.b[0, 12]

    return "image/jpeg"       if header.start_with?(JPEG_MAGIC)
    return "image/png"        if header.start_with?(PNG_MAGIC)
    return "application/pdf"  if header.start_with?(PDF_MAGIC)
    return "image/gif"        if header.start_with?(GIF_MAGIC)
    # WEBP: bytes 0-3 are "RIFF", bytes 8-11 are "WEBP"
    return "image/webp"       if header[0, 4] == WEBP_RIFF && header[8, 4] == WEBP_TYPE

    # Extension fallback when magic bytes are ambiguous
    case File.extname(filename).downcase
    when ".jpg", ".jpeg" then "image/jpeg"
    when ".png"          then "image/png"
    when ".pdf"          then "application/pdf"
    when ".webp"         then "image/webp"
    when ".gif"          then "image/gif"
    else "application/octet-stream"
    end
  end
end
