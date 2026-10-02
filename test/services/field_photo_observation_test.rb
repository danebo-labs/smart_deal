# frozen_string_literal: true

require "test_helper"

class FieldPhotoObservationTest < ActiveSupport::TestCase
  test "visual_observation is a nullable jsonb column on field_photos" do
    column = FieldPhoto.columns_hash.fetch("visual_observation")

    assert_equal :jsonb, column.type
    assert column.null
    assert_not FieldPhoto.connection.table_exists?(:visual_observations)
    assert_not FieldPhoto.column_names.include?("knowledge_scope")
  end

  test "destroy! removes the observation because it lives on the same row" do
    photo = create_photo
    stored = FieldPhotoObservation.persist!(photo, valid_raw)
    assert stored
    photo_id = photo.id

    photo.destroy!

    assert_nil FieldPhoto.find_by(id: photo_id)
  end

  test "sanitize keeps only the allowlist and drops model prose" do
    payload = FieldPhotoObservation.sanitize(valid_raw(
      "summary" => "prosa",
      "aliases" => [ "muelle" ],
      "documented_functions" => [ { "label" => "x" } ],
      "documented_connections" => [],
      "documented_values" => [],
      "documented_warnings" => [],
      "anti_hallucination_notes" => "nota",
      "analysis" => "build_analysis"
    ))

    assert_equal FieldPhotoObservation::KEYS, payload.keys
    assert_nil payload["summary"]
    assert_nil payload["aliases"]
    assert_equal "KONE", payload["manufacturer"]
  end

  test "from_analysis does not copy excluded model fields" do
    payload = FieldPhotoObservation.from_analysis(
      parsed: {
        "canonical_component" => "resortes",
        "manufacturer" => "KONE",
        "model" => "UNKNOWN",
        "subsystem" => "DOOR_OPERATOR",
        "condition" => "GOOD",
        "visible_text" => [],
        "summary" => "no guardar",
        "aliases" => [ "muelle" ],
        "anti_hallucination_notes" => "nota"
      },
      model_id: "claude-sonnet-5-5"
    )

    assert_equal FieldPhotoPrompt.prompt_fingerprint_sha256, payload["prompt_fingerprint"]
    assert_equal 1, payload["schema_version"]
    assert_not payload.key?("summary")
    assert_not payload.key?("aliases")
    assert FieldPhotoObservation.sanitize(payload)
  end

  test "rejects an invalid payload instead of truncating it" do
    photo = create_photo
    FieldPhotoObservation.persist!(photo, valid_raw)
    photo.reload
    original = photo.visual_observation

    [
      valid_raw("schema_version" => "1"),
      valid_raw("schema_version" => 2),
      valid_raw("prompt_fingerprint" => "abc"),
      valid_raw("prompt_fingerprint" => "A" * 64),
      valid_raw("model_id" => "m" * 81),
      valid_raw("canonical_component" => "c" * 81),
      valid_raw("manufacturer" => ""),
      valid_raw("model" => "m" * 81),
      valid_raw("subsystem" => "ELEVATOR"),
      valid_raw("condition" => "good"),
      valid_raw("visible_text" => Array.new(9) { "R1" }),
      valid_raw("visible_text" => [ "v" * 81 ]),
      valid_raw("visible_text" => "R1"),
      valid_raw("target_visible" => "true"),
      valid_raw("relevance_to_goal" => "sometimes"),
      oversized_raw
    ].each do |raw|
      assert_nil FieldPhotoObservation.sanitize(raw), raw.inspect
      assert_nil FieldPhotoObservation.persist!(photo, raw)
    end

    assert_equal original, photo.reload.visual_observation
    assert_equal 80, ("😀" * 80).length
    assert_operator JSON.generate(oversized_raw).bytesize, :>, FieldPhotoObservation::MAX_BYTES
  end

  test "a valid payload at the character cap is stored and stays within 2048 bytes when it fits" do
    raw = valid_raw(
      "canonical_component" => "c" * 80,
      "manufacturer" => "m" * 80,
      "model" => "UNKNOWN",
      "visible_text" => [ "R1" ],
      "target_visible" => nil,
      "relevance_to_goal" => nil
    )
    payload = FieldPhotoObservation.sanitize(raw)

    assert payload
    assert_operator JSON.generate(payload).bytesize, :<=, FieldPhotoObservation::MAX_BYTES
    assert_equal 80, payload["canonical_component"].length
  end

  test "subsystem and condition enums stay the FieldPhotoPrompt enums" do
    text = FieldPhotoPrompt::SYSTEM_BLOCKS.pluck(:text).join("\n")

    assert_equal FieldPhotoObservation::SUBSYSTEMS.join("|"), text[/"subsystem": "<([^>]+)>"/, 1]
    assert_equal FieldPhotoObservation::CONDITIONS.join("|"), text[/"condition": "<([^>]+)>"/, 1]
  end

  test "field photo model ids stay on the F2 and F2B constants" do
    assert_equal "claude-sonnet-5-5", BatchChunkingPrompt::MODEL_TEXT
    assert_equal "claude-opus-5-5", BatchChunkingPrompt::MODEL_MULTIMODAL
    assert_equal "claude-sonnet-5-5", FieldPhotoAnalysisService::DEFAULT_MODEL
  end

  test "from_analysis bounds identifiers and visible text without truncating them" do
    payload = FieldPhotoObservation.from_analysis(
      parsed: {
        "canonical_component" => "   ",
        "manufacturer" => "m" * 81,
        "model" => "  MX 20  ",
        "subsystem" => "DOOR_OPERATOR",
        "condition" => "GOOD",
        "visible_text" => [ "  R1  ", "", "R1", "v" * 81, "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9" ],
        "summary" => "no guardar",
        "target_visible" => true,
        "relevance_to_goal" => "relevant"
      },
      model_id: "  claude-sonnet-5-5  ",
      target_visible: false,
      relevance_to_goal: "unrelated"
    )

    assert_equal "UNKNOWN", payload["canonical_component"]
    assert_equal "UNKNOWN", payload["manufacturer"]
    assert_equal "MX 20", payload["model"]
    assert_equal [ "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8" ], payload["visible_text"]
    assert_equal "claude-sonnet-5-5", payload["model_id"]
    assert_equal false, payload["target_visible"]
    assert_equal "unrelated", payload["relevance_to_goal"]
    assert_not payload.key?("summary")
    assert FieldPhotoObservation.sanitize(payload)
  end

  test "from_analysis does not read target or relevance from the raw json" do
    payload = FieldPhotoObservation.from_analysis(
      parsed: {
        "canonical_component" => "resortes",
        "manufacturer" => "KONE",
        "model" => "UNKNOWN",
        "subsystem" => "DOOR_OPERATOR",
        "condition" => "GOOD",
        "visible_text" => [],
        "target_visible" => true,
        "relevance_to_goal" => "relevant"
      },
      model_id: "claude-sonnet-5-5"
    )

    assert_nil payload["target_visible"]
    assert_nil payload["relevance_to_goal"]
  end

  test "from_analysis drops visible text from the end until the envelope fits" do
    payload = FieldPhotoObservation.from_analysis(
      parsed: {
        "canonical_component" => "resortes",
        "manufacturer" => "KONE",
        "model" => "UNKNOWN",
        "subsystem" => "DOOR_OPERATOR",
        "condition" => "GOOD",
        "visible_text" => Array.new(8) { "😀" * 80 }
      },
      model_id: "claude-sonnet-5-5",
      target_visible: true,
      relevance_to_goal: "relevant"
    )

    assert payload["visible_text"].size < 8
    assert payload["visible_text"].all? { |item| item == "😀" * 80 }
    assert_operator JSON.generate(payload).bytesize, :<=, FieldPhotoObservation::MAX_BYTES
    assert FieldPhotoObservation.sanitize(payload)
  end

  test "accept! stores a bounded candidate and reports stored" do
    photo = create_photo
    acceptance = FieldPhotoObservation.accept!(
      photo: photo,
      parsed: component_parsed,
      model_id: "claude-sonnet-5-5",
      target_visible: true,
      relevance_to_goal: "relevant"
    )

    assert_equal "stored", acceptance.status
    assert_nil acceptance.reason
    assert_equal acceptance.observation, photo.reload.visual_observation
    assert_equal "KONE", acceptance.observation["manufacturer"]
  end

  test "accept! rejects an invalid enum without replacing a stored observation" do
    photo = create_photo
    FieldPhotoObservation.persist!(photo, valid_raw)
    original = photo.reload.visual_observation

    acceptance = FieldPhotoObservation.accept!(
      photo: photo,
      parsed: component_parsed("condition" => "good", "subsystem" => "ELEVATOR"),
      model_id: "m" * 3000,
      target_visible: "true",
      relevance_to_goal: "sometimes"
    )

    assert_equal "invalid", acceptance.status
    assert_equal "invalid_enum", acceptance.reason
    assert_nil acceptance.observation
    assert_equal original, photo.reload.visual_observation
    assert_equal "good", FieldPhotoObservation.from_analysis(
      parsed: component_parsed("condition" => "good"),
      model_id: "claude-sonnet-5-5"
    )["condition"]
  end

  test "accept! reports over_budget when emptying visible text is not enough" do
    photo = create_photo
    FieldPhotoObservation.persist!(photo, valid_raw)
    original = photo.reload.visual_observation

    acceptance = FieldPhotoObservation.accept!(
      photo: photo,
      parsed: component_parsed("visible_text" => []),
      model_id: "m" * 3000,
      target_visible: true,
      relevance_to_goal: "relevant"
    )

    assert_equal "invalid", acceptance.status
    assert_equal "over_budget", acceptance.reason
    assert_equal original, photo.reload.visual_observation
  end

  test "accept! reports invalid_shape and unavailable without writing" do
    photo = create_photo
    FieldPhotoObservation.persist!(photo, valid_raw)
    original = photo.reload.visual_observation

    shape = FieldPhotoObservation.accept!(
      photo: photo,
      parsed: component_parsed("visible_text" => "R1"),
      model_id: "m" * 81,
      target_visible: true,
      relevance_to_goal: "relevant"
    )
    missing = FieldPhotoObservation.accept!(
      photo: nil,
      parsed: component_parsed,
      model_id: "claude-sonnet-5-5"
    )
    photo.define_singleton_method(:update!) { |*, **| raise ActiveRecord::ActiveRecordError, "locked" }
    failed = FieldPhotoObservation.accept!(
      photo: photo,
      parsed: component_parsed,
      model_id: "claude-sonnet-5-5",
      target_visible: true,
      relevance_to_goal: "relevant"
    )

    assert_equal "invalid", shape.status
    assert_equal "invalid_shape", shape.reason
    assert_equal "unavailable", missing.status
    assert_equal "persistence_failure", missing.reason
    assert_equal "unavailable", failed.status
    assert_equal "persistence_failure", failed.reason
    assert_equal original, photo.reload.visual_observation
  end

  test "persisting an observation does not create a document or a knowledge scope" do
    photo = create_photo

    assert_no_difference("KbDocument.count") do
      FieldPhotoObservation.persist!(photo, valid_raw)
    end

    assert_not photo.reload.s3_key_original.include?("bulk_chunks/")
  end

  private

  def create_photo
    account = accounts(:legacy)
    sha = SecureRandom.hex(32)
    FieldPhoto.create!(
      account: account,
      sha256: sha,
      s3_key_original: "field_photos/#{account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg",
      byte_size: 12
    )
  end

  def component_parsed(overrides = {})
    {
      "canonical_component" => "resortes",
      "manufacturer" => "KONE",
      "model" => "UNKNOWN",
      "subsystem" => "DOOR_OPERATOR",
      "condition" => "GOOD",
      "visible_text" => [ "R1" ]
    }.merge(overrides)
  end

  def valid_raw(overrides = {})
    {
      "schema_version" => 1,
      "prompt_fingerprint" => "a" * 64,
      "model_id" => "claude-sonnet-5-5",
      "canonical_component" => "resortes",
      "manufacturer" => "KONE",
      "model" => "UNKNOWN",
      "subsystem" => "DOOR_OPERATOR",
      "condition" => "DEGRADED",
      "visible_text" => [ "R1" ],
      "target_visible" => true,
      "relevance_to_goal" => "relevant"
    }.merge(overrides)
  end

  def oversized_raw
    valid_raw("visible_text" => Array.new(8) { "😀" * 80 })
  end
end
