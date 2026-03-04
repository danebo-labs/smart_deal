# frozen_string_literal: true

# app/services/image_compression_service.rb
# Compresses images to meet Amazon Bedrock Knowledge Base limits (10MB base64 encoded).
# Optimizes images to 1-5MB for best performance.
class ImageCompressionService
  MAX_DIMENSION = 1024
  JPEG_QUALITY = 80
  MAX_BASE64_SIZE = 10_000_000 # 10MB in bytes

  class CompressionError < StandardError; end

  # Compresses a base64-encoded image
  #
  # @param base64_data [String] Base64-encoded image data
  # @param media_type [String] MIME type (e.g., "image/jpeg", "image/png")
  # @return [Hash] { data: compressed_base64, media_type: "image/jpeg", original_size: bytes, compressed_size: bytes }
  # @raise [CompressionError] If compression fails
  def self.compress(base64_data, media_type)
    new(base64_data, media_type).compress
  end

  def initialize(base64_data, media_type)
    @base64_data = base64_data
    @media_type = media_type
    @original_size = base64_data.bytesize
  end

  def compress
    return skip_compression if should_skip_compression?

    compressed_blob = process_image
    compressed_base64 = Base64.strict_encode64(compressed_blob)

    {
      data: compressed_base64,
      media_type: "image/jpeg",
      original_size: @original_size,
      compressed_size: compressed_base64.bytesize
    }
  rescue StandardError => e
    Rails.logger.error("ImageCompressionService: Failed to compress image: #{e.message}")
    raise CompressionError, "Failed to compress image: #{e.message}"
  end

  private

  def should_skip_compression?
    @original_size < 500_000 || @base64_data.blank?
  end

  def skip_compression
    Rails.logger.info("ImageCompressionService: Skipping compression (size: #{@original_size} bytes)")
    {
      data: @base64_data,
      media_type: @media_type,
      original_size: @original_size,
      compressed_size: @original_size
    }
  end

  def process_image
    image_blob = decode_base64
    raise CompressionError, "Decoded image data is empty" if image_blob.empty?

    source_io = StringIO.new(image_blob)

    processed = ImageProcessing::Vips
      .source(source_io)
      .resize_to_limit(MAX_DIMENSION, MAX_DIMENSION)
      .convert("jpeg")
      .saver(quality: JPEG_QUALITY)
      .call

    compressed_blob = processed.read
    validate_size!(compressed_blob)

    log_compression_result(compressed_blob)
    compressed_blob
  rescue Vips::Error => e
    raise CompressionError, "Image processing failed: #{e.message}"
  ensure
    processed&.close
    source_io&.close
  end

  def decode_base64
    decoded = Base64.decode64(@base64_data)
    raise CompressionError, "Invalid base64 data: decoded content is empty" if decoded.empty?
    decoded
  rescue ArgumentError => e
    raise CompressionError, "Invalid base64 data: #{e.message}"
  end

  def validate_size!(blob)
    encoded_size = Base64.strict_encode64(blob).bytesize
    return if encoded_size <= MAX_BASE64_SIZE

    raise CompressionError, "Compressed image (#{encoded_size} bytes) exceeds Bedrock limit (#{MAX_BASE64_SIZE} bytes)"
  end

  def log_compression_result(compressed_blob)
    reduction_pct = ((@original_size - compressed_blob.bytesize).to_f / @original_size * 100).round(1)
    Rails.logger.info(
      "ImageCompressionService: Compressed #{@original_size} -> #{compressed_blob.bytesize} bytes (#{reduction_pct}% reduction)"
    )
  end
end
