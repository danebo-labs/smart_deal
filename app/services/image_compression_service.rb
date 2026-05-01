# frozen_string_literal: true

# app/services/image_compression_service.rb
# Compresses images to meet Amazon Bedrock Knowledge Base limits.
# Bedrock KB ingestion: JPEG/PNG max 3.75 MB per file (see knowledge-base-ds.html).
#
# Design notes:
# - Decodes base64 exactly once and caches the binary (@decoded_blob) for all
#   subsequent operations (skip check, Vips processing, size logging).
# - Exposes #decoded_binary so callers (e.g. S3 upload) can access the raw bytes
#   without decoding the base64 a second time.
# - Uses a single Vips pass: quality is estimated from the decoded size ratio so
#   the resize→convert→save pipeline runs only once (with one fallback at q=40
#   for extreme cases).
class ImageCompressionService
  MAX_DIMENSION      = 1024
  MAX_BINARY_BYTES   = (3.75 * 1024 * 1024).to_i  # 3.75 MB in bytes
  THUMB_MAX_WIDTH    = 88   # px — fits 44×44 Tailwind h-11 w-11 at 2x DPR
  THUMB_QUALITY      = 70

  class CompressionError < StandardError; end

  # @param base64_data [String] Base64-encoded image data
  # @param media_type  [String] MIME type (e.g., "image/jpeg", "image/png")
  # @return [Hash] {
  #   data: String (compressed base64),
  #   media_type: "image/jpeg",
  #   binary: String (raw bytes — use this for S3 upload to skip re-decode),
  #   original_size: Integer,
  #   compressed_size: Integer
  # }
  # @raise [CompressionError]
  def self.compress(base64_data, media_type)
    new(base64_data, media_type).compress
  end

  # Same as compress but also produces a small JPEG thumbnail in a single Vips load.
  # Thumbnail is 88 px wide (2x DPR of the 44 px mobile cell), q=70 — typically ≤15 KB.
  # @return [Hash] compress result merged with:
  #   thumbnail_binary:       String (raw JPEG bytes)
  #   thumbnail_content_type: "image/jpeg"
  #   thumbnail_width:        Integer
  #   thumbnail_height:       Integer
  def self.compress_with_thumbnail(base64_data, media_type)
    new(base64_data, media_type).compress_with_thumbnail
  end

  def initialize(base64_data, media_type)
    @base64_data   = base64_data
    @media_type    = media_type
    @original_size = base64_data.bytesize
    @decoded_blob  = nil  # decoded once, lazily cached
  end

  def compress
    return skip_compression if should_skip_compression?

    compressed_blob   = process_image
    compressed_base64 = Base64.strict_encode64(compressed_blob)

    {
      data:            compressed_base64,
      media_type:      "image/jpeg",
      binary:          compressed_blob,
      original_size:   @original_size,
      compressed_size: compressed_base64.bytesize
    }
  rescue StandardError => e
    Rails.logger.error("ImageCompressionService: Failed to compress image: #{e.message}")
    raise CompressionError, "Failed to compress image: #{e.message}"
  end

  # Compresses the main image AND generates a thumbnail in a single Vips load.
  # Falls back to compress-only (no thumbnail) on any Vips error so the upload
  # still succeeds even if thumbnail generation fails.
  def compress_with_thumbnail
    result        = compress
    thumb_payload = build_thumbnail(decoded_blob)

    result.merge(thumb_payload)
  rescue StandardError => e
    Rails.logger.warn("ImageCompressionService: thumbnail generation failed (#{e.message}); proceeding without thumb")
    compress.merge(thumbnail_binary: nil, thumbnail_content_type: nil, thumbnail_width: nil, thumbnail_height: nil)
  end

  private

  # Decoded bytes cached for the lifetime of this instance.
  def decoded_blob
    @decoded_blob ||= begin
      blob = Base64.decode64(@base64_data)
      raise CompressionError, "Invalid base64 data: decoded content is empty" if blob.empty?
      blob
    end
  rescue ArgumentError => e
    raise CompressionError, "Invalid base64 data: #{e.message}"
  end

  def should_skip_compression?
    return true if @base64_data.blank?

    decoded_blob.bytesize <= MAX_BINARY_BYTES
  rescue CompressionError
    false
  end

  def skip_compression
    Rails.logger.debug { "ImageCompressionService: Skipping compression (decoded: #{decoded_blob.bytesize} bytes)" }
    {
      data:            @base64_data,
      media_type:      @media_type,
      binary:          decoded_blob,
      original_size:   @original_size,
      compressed_size: @original_size
    }
  end

  # Single-pass Vips compression with quality estimated from the size ratio.
  # Falls back to quality=40 only when the first pass still exceeds the limit
  # (handles pathological cases like near-lossless PNGs at huge resolutions).
  def process_image
    blob    = decoded_blob
    quality = estimate_quality(blob.bytesize)

    result = run_vips(blob, quality)

    if result.bytesize > MAX_BINARY_BYTES
      Rails.logger.warn("ImageCompressionService: q=#{quality} still #{result.bytesize} bytes, retrying at q=40")
      result = run_vips(blob, 40)
    end

    validate_size!(result)
    log_compression_result(result)
    result
  rescue Vips::Error => e
    raise CompressionError, "Image processing failed: #{e.message}"
  end

  def build_thumbnail(blob)
    img        = Vips::Image.new_from_buffer(blob, "").thumbnail_image(THUMB_MAX_WIDTH, size: :down)
    thumb_blob = img.write_to_buffer(".jpg[Q=#{THUMB_QUALITY}]")
    {
      thumbnail_binary:       thumb_blob,
      thumbnail_content_type: "image/jpeg",
      thumbnail_width:        img.width,
      thumbnail_height:       img.height
    }
  rescue Vips::Error => e
    raise CompressionError, "Thumbnail generation failed: #{e.message}"
  end

  def run_vips(blob, quality)
    source_io = StringIO.new(blob)
    processed = ImageProcessing::Vips
      .source(source_io)
      .resize_to_limit(MAX_DIMENSION, MAX_DIMENSION)
      .convert("jpeg")
      .saver(quality: quality)
      .call
    result = processed.read
    processed.close
    source_io.close
    result
  end

  # Maps decoded binary size to a JPEG quality level.
  # Rationale: images already compressed by the client (Canvas) will be small
  # (ratio ≤ 1) and skip compression entirely; this handles server-only uploads
  # or cases where the client fallback was used.
  def estimate_quality(decoded_bytes)
    ratio = decoded_bytes.to_f / MAX_BINARY_BYTES
    if    ratio <= 1.5 then 82
    elsif ratio <= 3.0 then 70
    elsif ratio <= 6.0 then 55
    else                    42
    end
  end

  def validate_size!(blob)
    return if blob.bytesize <= MAX_BINARY_BYTES

    raise CompressionError,
          "Compressed image (#{blob.bytesize} bytes) still exceeds Bedrock KB limit (#{MAX_BINARY_BYTES} bytes / 3.75 MB)"
  end

  def log_compression_result(compressed_blob)
    reduction_pct = ((@original_size - compressed_blob.bytesize).to_f / @original_size * 100).round(1)
    Rails.logger.info(
      "ImageCompressionService: Compressed #{@original_size} -> #{compressed_blob.bytesize} bytes (#{reduction_pct}% reduction)"
    )
  end
end
