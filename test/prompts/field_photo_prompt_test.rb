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

  test "live-photo contract version constant is gone and the ingestion contract is unchanged" do
    assert_not FieldPhotoPrompt.const_defined?(:CONTRACT_VERSION)
    assert_equal "field_photo_records_v3", FieldPhotoPrompt::INGESTION_CONTRACT_VERSION
  end

  test "prompt fingerprint stays the pre-phase-1 SYSTEM_BLOCKS digest" do
    assert_equal "4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1",
                 FieldPhotoPrompt.prompt_fingerprint_sha256
  end

  test "user content without an intent matches the ingestion user content" do
    kwargs = { binary: FAKE_BINARY, content_type: FAKE_CT, filename: FAKE_NAME, locale: "es" }
    content = FieldPhotoPrompt.user_content(**kwargs)
    assert_equal BatchChunkingPrompt.user_content(**kwargs), content
    texts = content.select { |block| block[:type] == "text" }.pluck(:text)
    assert texts.none? { |text| text.include?("Photo intent") }
  end

  test "user content without active work matches the ingestion user content" do
    kwargs = { binary: FAKE_BINARY, content_type: FAKE_CT, filename: FAKE_NAME, locale: "es" }
    context = { "schema_version" => 1, "mode" => "standalone" }
    content = FieldPhotoPrompt.user_content(**kwargs, visual_task_context: context)
    assert_equal BatchChunkingPrompt.user_content(**kwargs), content
  end

  test "user content with a visual task appends the task and the three keys" do
    task = "Cómo se ajustan los resortes de la fijación de cables"
    content = FieldPhotoPrompt.user_content(
      binary: FAKE_BINARY,
      content_type: FAKE_CT,
      filename: FAKE_NAME,
      locale: "es",
      visual_task_context: {
        "schema_version" => 1,
        "mode" => "standalone",
        "visual_task" => { "text" => task, "source" => "question" }
      }
    )
    text = content.reverse.find { |block| block[:type] == "text" }[:text]
    assert_includes text, "CONTEXT IS NOT EVIDENCE"
    assert_includes text, task
    assert_includes text, '"target_visible": true | false | null'
    assert_includes text, '"relevance_to_goal": "relevant" | "unrelated" | "uncertain"'
    assert_includes text, '"missing_view_or_detail":'
    assert_includes text, "primary relevance anchor is visual_task"
    assert_equal 1, content.count { |block| block[:type] == "text" && block[:text].include?("CONTEXT IS NOT EVIDENCE") }
    assert_equal "4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1",
                 FieldPhotoPrompt.prompt_fingerprint_sha256
  end

  test "live visual task requests safe best effort guidance and optional evidence without a procedure" do
    content = FieldPhotoPrompt.user_content(
      binary: FAKE_BINARY,
      content_type: FAKE_CT,
      filename: FAKE_NAME,
      locale: "es",
      visual_task_context: {
        "schema_version" => 1,
        "mode" => "standalone",
        "visual_task" => { "text" => "Cómo se ajustan estos resortes", "source" => "question" }
      }
    )
    text = content.reverse.find { |block| block[:type] == "text" }[:text]

    assert_includes text, 'Use "summary" to answer the intent only as far as this image safely supports'
    assert_includes text, "one non-invasive component-specific check"
    assert_includes text, "Additional evidence improves accuracy"
    assert_includes text, "starting with the equivalent of 'If you can'"
    assert_includes text, "Do not give torque, settings, turn counts, target values"
    assert_includes text, "equipment-specific adjustment procedures"
    assert_not_includes text, "Do not answer the question"
  end

  test "active work without a visual task asks for relevance and leaves the target unset" do
    content = FieldPhotoPrompt.user_content(
      binary: FAKE_BINARY,
      content_type: FAKE_CT,
      filename: FAKE_NAME,
      locale: "es",
      visual_task_context: {
        "schema_version" => 1,
        "mode" => "ongoing_episode",
        "goal" => "no nivela en planta 3"
      }
    )
    text = content.reverse.find { |block| block[:type] == "text" }[:text]

    assert_includes text, "no nivela en planta 3"
    assert_includes text, "CONTEXT IS NOT EVIDENCE"
    assert_includes text, "There is no visual task"
    assert_includes text, "even if the fault itself is not in frame"
    assert_includes text, '"target_visible": null'
    assert_not_includes text, "visual_task"
    assert_not_includes text, "primary relevance anchor"
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
