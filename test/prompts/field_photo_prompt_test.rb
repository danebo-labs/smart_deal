# frozen_string_literal: true

require "test_helper"

class FieldPhotoPromptTest < ActiveSupport::TestCase
  FAKE_BINARY = "\xFF\xD8 fake jpeg bytes"
  FAKE_CT     = "image/jpeg"
  FAKE_NAME   = "motor_photo.jpg"

  test "SYSTEM_BLOCKS contains one block with cache_control ephemeral" do
    assert_equal 1, FieldPhotoPrompt::SYSTEM_BLOCKS.size
    block = FieldPhotoPrompt::SYSTEM_BLOCKS.first
    assert_equal "text", block[:type]
    assert_equal({ type: "ephemeral" }, block[:cache_control])
    assert_includes block[:text], "canonical_component"
  end

  test "user_content returns array with image block for jpeg" do
    content = FieldPhotoPrompt.user_content(
      binary:       FAKE_BINARY,
      content_type: FAKE_CT,
      filename:     FAKE_NAME
    )

    assert_kind_of Array, content
    image_block = content.find { |b| b[:type] == "image" }
    assert_not_nil image_block, "expected an image block"
    assert_equal "base64", image_block.dig(:source, :type)
    assert_equal FAKE_CT,  image_block.dig(:source, :media_type)
  end

  test "user_content includes Summary language hint when locale present" do
    content = FieldPhotoPrompt.user_content(
      binary:       FAKE_BINARY,
      content_type: FAKE_CT,
      filename:     FAKE_NAME,
      locale:       "es"
    )

    texts = content.select { |b| b[:type] == "text" }.pluck(:text)
    assert texts.any? { |t| t.include?("Summary language: es") },
           "expected locale hint in content blocks"
  end

  test "user_content omits locale hint when locale is nil" do
    content = FieldPhotoPrompt.user_content(
      binary:       FAKE_BINARY,
      content_type: FAKE_CT,
      filename:     FAKE_NAME
    )

    texts = content.select { |b| b[:type] == "text" }.pluck(:text)
    assert_not texts.any? { |t| t.include?("Summary language") }
  end
end
