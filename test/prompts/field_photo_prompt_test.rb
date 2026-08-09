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
    assert_includes block[:text], "documented_functions"
    assert_includes block[:text], "documented_connections"
    assert_includes block[:text], "documented_values"
    assert_includes block[:text], "does NOT prove function"
  end

  test "SYSTEM_BLOCKS carries an absolute language directive for prose fields, defaulting to Spanish" do
    text = FieldPhotoPrompt::SYSTEM_BLOCKS.first[:text]

    assert_includes text, "LANGUAGE:"
    assert_includes text, "canonical_component, summary, anti_hallucination_notes"
    assert_includes text, "Default to Spanish when that hint is absent"
    assert_includes text, "absolute requirement"
    # Evidence/verbatim fields are explicitly exempt from translation.
    assert_includes text, "never translate or paraphrase these"
  end

  test "CONTRACT_VERSION is bumped to v2 to invalidate diagnoses cached under the weaker language hint" do
    assert_equal "v2", FieldPhotoPrompt::CONTRACT_VERSION
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
