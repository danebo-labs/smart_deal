# frozen_string_literal: true

# Durable storage for a company's report logo (Fase 1A).
#
# Deliberately NOT a FieldPhoto: field photos are evidence with a retention TTL
# and a diagnosis pipeline, and a brand mark must never be purged or analyzed.
# Its own prefix, keyed by content digest, so replacing a logo writes a new
# object instead of overwriting bytes an already generated export may still be
# pointing at. Nothing here deletes S3 objects — no automatic cleanup in this
# fase (see the closure for the cleanup policy).
#
# The format is decided by the real bytes, not by the declared content type or
# the filename: an SVG or a PDF renamed to .png is rejected. Only PNG and JPEG
# pass, since those are the two formats the print/PDF template can rely on.
class CertifierLogoStore
  PREFIX = "certifier_assets"

  MAX_BYTES  = 2 * 1024 * 1024 # 2 MB
  MAX_PIXELS = 4_000_000       # 4 megapixels

  # Sniffed from the leading bytes. JPEG is checked by SOI only: the EOI marker
  # is unreliable on progressive/truncated-but-valid files.
  PNG_MAGIC  = "\x89PNG\r\n\x1A\n".b
  JPEG_MAGIC = "\xFF\xD8\xFF".b

  Result = Struct.new(:s3_key, :content_type, :byte_size, :sha256, :error, keyword_init: true) do
    def ok?
      error.nil?
    end
  end

  # @param uploaded_file [ActionDispatch::Http::UploadedFile]
  # @param account_id [Integer]
  # @return [Result] ok? with the metadata to persist, or an error key for i18n.
  #   On any error the caller keeps the previous logo untouched.
  def self.call(uploaded_file, account_id:)
    return failure(:missing) if uploaded_file.blank? || account_id.blank?

    binary = uploaded_file.read.to_s.b
    return failure(:missing) if binary.empty?
    return failure(:too_large) if binary.bytesize > MAX_BYTES

    content_type = sniff_content_type(binary)
    return failure(:unsupported_format) if content_type.nil?

    pixels = pixel_count(binary)
    return failure(:unreadable) if pixels.nil?
    return failure(:too_many_pixels) if pixels > MAX_PIXELS

    normalized = normalize(binary, content_type)
    return failure(:unreadable) if normalized.nil?

    store(normalized, account_id: account_id)
  end

  # Passes the bytes through the compression service already used for photos so
  # there is one image pipeline in the app. Below MAX_BYTES that service is a
  # pass-through, which is what a logo wants: a PNG keeps its transparency and
  # is not re-encoded to JPEG over a white background.
  def self.normalize(binary, content_type)
    compressed = ImageCompressionService.compress(Base64.strict_encode64(binary), content_type)
    { binary: compressed[:binary], content_type: compressed[:media_type].presence || content_type }
  rescue ImageCompressionService::CompressionError => e
    Rails.logger.warn("CertifierLogoStore: normalization failed — #{e.message}")
    nil
  end
  private_class_method :normalize

  def self.store(normalized, account_id:)
    binary  = normalized[:binary]
    sha256  = Digest::SHA256.hexdigest(binary)
    key     = object_key(account_id: account_id, sha256: sha256, content_type: normalized[:content_type])

    return failure(:upload_failed) unless S3DocumentsService.new.upload_binary(key, binary, normalized[:content_type])

    Result.new(s3_key: key, content_type: normalized[:content_type],
               byte_size: binary.bytesize, sha256: sha256)
  end
  private_class_method :store

  def self.sniff_content_type(binary)
    return "image/png"  if binary.start_with?(PNG_MAGIC)
    return "image/jpeg" if binary.start_with?(JPEG_MAGIC)

    nil
  end
  private_class_method :sniff_content_type

  def self.pixel_count(binary)
    image = Vips::Image.new_from_buffer(binary, "")
    image.width * image.height
  rescue StandardError => e
    Rails.logger.warn("CertifierLogoStore: could not read image dimensions — #{e.message}")
    nil
  end
  private_class_method :pixel_count

  def self.object_key(account_id:, sha256:, content_type:)
    ext = content_type == "image/png" ? "png" : "jpg"
    "#{PREFIX}/#{account_id}/#{sha256}/logo.#{ext}"
  end
  private_class_method :object_key

  def self.failure(error)
    Result.new(error: error)
  end
  private_class_method :failure
end
