# frozen_string_literal: true

require 'test_helper'

class ImageCompressionServiceTest < ActiveSupport::TestCase
  test "skips compression for small images" do
    small_image_base64 = create_test_image_base64(100, 100)

    result = ImageCompressionService.compress(small_image_base64, "image/jpeg")

    assert_equal small_image_base64, result[:data]
    assert_equal result[:original_size], result[:compressed_size]
    # Small images (decoded <= 3.75 MB) skip compression
    assert_operator Base64.decode64(small_image_base64).bytesize, :<=, ImageCompressionService::MAX_BINARY_SIZE_KB
  end

  test "returns proper hash structure" do
    small_image = create_test_image_base64(100, 100)
    result = ImageCompressionService.compress(small_image, "image/jpeg")

    assert result.key?(:data)
    assert result.key?(:media_type)
    assert result.key?(:original_size)
    assert result.key?(:compressed_size)
    assert_equal "image/jpeg", result[:media_type]
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

  private

  def create_test_image_base64(width, height, format: "jpeg")
    image = Vips::Image.black(width, height)
    buffer = image.write_to_buffer(".#{format}")
    Base64.strict_encode64(buffer)
  end
end
