# frozen_string_literal: true

require 'test_helper'

class ImageCompressionServiceTest < ActiveSupport::TestCase
  test "skips compression for small images" do
    small_image_base64 = create_test_image_base64(100, 100)

    result = ImageCompressionService.compress(small_image_base64, "image/jpeg")

    assert_equal small_image_base64, result[:data]
    assert_equal result[:original_size], result[:compressed_size]
    # Small images (decoded <= 3.75 MB) skip compression
    assert_operator Base64.decode64(small_image_base64).bytesize, :<=, ImageCompressionService::MAX_BINARY_BYTES
  end

  test "returns proper hash structure" do
    small_image = create_test_image_base64(100, 100)
    result = ImageCompressionService.compress(small_image, "image/jpeg")

    assert result.key?(:data)
    assert result.key?(:media_type)
    assert result.key?(:binary)
    assert result.key?(:original_size)
    assert result.key?(:compressed_size)
    assert_equal "image/jpeg", result[:media_type]
    assert_kind_of String, result[:binary]
    assert_not result[:binary].empty?
  end

  test "raises error for invalid image data" do
    # Create data large enough to trigger compression (> 3.75 MB decoded) but not a valid image
    invalid_image = Base64.strict_encode64("X" * 4_000_000)

    error = assert_raises(ImageCompressionService::CompressionError) do
      ImageCompressionService.compress(invalid_image, "image/jpeg")
    end

    assert_match(/processing failed|empty|invalid/i, error.message)
  end

  test "integration: compresses a real large JPEG" do
    # This would be tested manually with a real uploaded image
    # or with a fixture large enough to trigger compression
    skip "Manual integration test: Upload a large JPEG (>500KB) via UI to verify compression"
  end

  # ── compress_with_thumbnail ────────────────────────────────────────────────

  test "compress_with_thumbnail returns thumbnail keys" do
    img_base64 = create_test_image_base64(200, 150)
    result = ImageCompressionService.compress_with_thumbnail(img_base64, "image/jpeg")

    assert result.key?(:thumbnail_binary)
    assert result.key?(:thumbnail_content_type)
    assert result.key?(:thumbnail_width)
    assert result.key?(:thumbnail_height)
    assert_equal "image/jpeg", result[:thumbnail_content_type]
  end

  test "compress_with_thumbnail produces thumbnail within expected size" do
    img_base64 = create_test_image_base64(400, 300)
    result = ImageCompressionService.compress_with_thumbnail(img_base64, "image/jpeg")

    assert result[:thumbnail_binary].is_a?(String)
    assert_operator result[:thumbnail_binary].bytesize, :>, 0
    assert_operator result[:thumbnail_binary].bytesize, :<=, 30_000, "thumbnail should be ≤30 KB"
  end

  test "compress_with_thumbnail thumbnail width does not exceed THUMB_MAX_WIDTH" do
    img_base64 = create_test_image_base64(400, 300)
    result = ImageCompressionService.compress_with_thumbnail(img_base64, "image/jpeg")

    assert_operator result[:thumbnail_width], :<=, ImageCompressionService::THUMB_MAX_WIDTH
  end

  test "compress_with_thumbnail still returns main compressed image" do
    img_base64 = create_test_image_base64(200, 150)
    result = ImageCompressionService.compress_with_thumbnail(img_base64, "image/jpeg")

    assert result.key?(:data)
    assert result.key?(:binary)
    assert_equal "image/jpeg", result[:media_type]
  end

  # ── Gate 9R O1′ prep: before/after telemetry ────────────────────────────────

  test "skip path emits image_compression event with bytes and dimensions (skipped: true)" do
    img_base64 = create_test_image_base64(120, 80)

    logged = capture_info_logs do
      ImageCompressionService.compress(img_base64, "image/jpeg")
    end

    line = logged.find { |l| l.include?("\"event\":\"image_compression\"") }
    assert line, "expected an image_compression telemetry event"

    event = JSON.parse(line)
    assert event["skipped"], "≤3.75MB binaries must skip the resize (current behavior)"
    assert_equal "bytes<=#{ImageCompressionService::MAX_BINARY_BYTES}", event["skip_reason"]
    assert_equal Base64.decode64(img_base64).bytesize, event["bytes_before"]
    assert_equal event["bytes_before"], event["bytes_after"], "skip must not change bytes"
    assert_equal 120, event["width_before"]
    assert_equal 80,  event["height_before"]
    assert_equal 120, event["width_after"]
    assert_equal 80,  event["height_after"]
  end

  test "telemetry failure does not break compression result" do
    img_base64 = create_test_image_base64(60, 40)

    original = Rails.logger.method(:info)
    Rails.logger.define_singleton_method(:info) { |*| raise "logger down" }

    result = ImageCompressionService.compress(img_base64, "image/jpeg")
    assert_equal img_base64, result[:data]
  ensure
    Rails.logger.define_singleton_method(:info) { |msg = nil, &blk| original.call(msg, &blk) }
  end

  private

  def capture_info_logs
    logged = []
    original = Rails.logger.method(:info)
    Rails.logger.define_singleton_method(:info) { |msg = nil, &blk| logged << (msg || blk&.call).to_s }
    yield
    logged
  ensure
    Rails.logger.define_singleton_method(:info) { |msg = nil, &blk| original.call(msg, &blk) }
  end

  def create_test_image_base64(width, height, format: "jpeg")
    image = Vips::Image.black(width, height)
    buffer = image.write_to_buffer(".#{format}")
    Base64.strict_encode64(buffer)
  end
end
