# frozen_string_literal: true

# app/services/image_compression_service.rb
# Compresses images to meet Amazon Bedrock Knowledge Base limits.
# Bedrock KB ingestion: JPEG/PNG max 3.75 MB per file (see knowledge-base-ds.html).
class ImageCompressionService
  MAX_DIMENSION = 1024
  # Bedrock KB ingestion limit for images
  MAX_BINARY_SIZE_KB = (3.75 * 1024 * 1024).to_i
  QUALITY_LEVELS = [ 80, 70, 60, 50, 40 ].freeze

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
    return true if @base64_data.blank?

    decoded = Base64.decode64(@base64_data)
    decoded.bytesize <= MAX_BINARY_SIZE_KB
  rescue ArgumentError
    false
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

    # Iteratively reduce quality until under Bedrock KB limit (3.75 MB)
    QUALITY_LEVELS.each do |quality|
      source_io = StringIO.new(image_blob)
      processed = ImageProcessing::Vips
        .source(source_io)
        .resize_to_limit(MAX_DIMENSION, MAX_DIMENSION)
        .convert("jpeg")
        .saver(quality: quality)
        .call
      blob = processed.read
      processed.close
      source_io.close

      next if blob.bytesize > MAX_BINARY_SIZE_KB

      validate_size!(blob)
      log_compression_result(blob)
      return blob
    end

    raise CompressionError,
          "Image still exceeds Bedrock KB limit (#{MAX_BINARY_SIZE_KB} bytes / 3.75 MB) after compression"
  rescue Vips::Error => e
    raise CompressionError, "Image processing failed: #{e.message}"
  end

  def decode_base64
    decoded = Base64.decode64(@base64_data)
    raise CompressionError, "Invalid base64 data: decoded content is empty" if decoded.empty?
    decoded
  rescue ArgumentError => e
    raise CompressionError, "Invalid base64 data: #{e.message}"
  end

  def validate_size!(blob)
    return if blob.bytesize <= MAX_BINARY_SIZE_KB

    raise CompressionError,
          "Compressed image (#{blob.bytesize} bytes) exceeds Bedrock KB limit (#{MAX_BINARY_SIZE_KB} bytes / 3.75 MB)"
  end

  def log_compression_result(compressed_blob)
    reduction_pct = ((@original_size - compressed_blob.bytesize).to_f / @original_size * 100).round(1)
    Rails.logger.info(
      "ImageCompressionService: Compressed #{@original_size} -> #{compressed_blob.bytesize} bytes (#{reduction_pct}% reduction)"
    )
  end
end
