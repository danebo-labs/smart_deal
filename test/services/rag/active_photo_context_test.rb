# frozen_string_literal: true

require "test_helper"

class Rag::ActivePhotoContextTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:legacy)
    @other = accounts(:climb)
    @now = Time.current
  end

  test "no active photo is a no-op" do
    context = Rag::ActivePhotoContext.resolve(episode: Rag::ActiveEpisode.new, viewer_account: @account)

    assert_equal "absent", context.status
    assert_nil context.to_prompt
    assert_empty context.query_terms
    assert_nil context.generation_block
  end

  test "a foreign photo id is unavailable and is not replaced" do
    foreign = create_photo(@other, observation(relevance: "relevant", model: "SECRET"))
    episode = episode_with(foreign.id)
    context = Rag::ActivePhotoContext.resolve(episode: episode, viewer_account: @account)

    assert_equal "unavailable", context.status
    assert_nil context.to_prompt
    assert_not_includes context.inspect, "SECRET"
  end

  test "a missing id and an invalid observation do not fall back to another photo" do
    create_photo(@account, observation(model: "OTHER"))
    missing = Rag::ActivePhotoContext.resolve(episode: episode_with(0), viewer_account: @account)
    photo = create_photo(@account, { "schema_version" => 1 })
    invalid = Rag::ActivePhotoContext.resolve(episode: episode_with(photo.id), viewer_account: @account)

    assert_equal "unavailable", missing.status
    assert_equal "invalid", invalid.status
    assert_nil invalid.to_prompt
  end

  test "only a relevant photo produces query terms and a generation block" do
    %w[relevant uncertain unrelated].each do |relevance|
      photo = create_photo(@account, observation(relevance: relevance, model: "NICE3000", manufacturer: "NICE", codes: [ "E51" ]))
      context = Rag::ActivePhotoContext.resolve(episode: episode_with(photo.id), viewer_account: @account)

      assert_equal "loaded", context.status
      assert_equal relevance, context.to_prompt["relevance_to_goal"]
      assert_equal "photo", context.to_prompt["source"]
      assert_not context.to_prompt.key?("prompt_fingerprint")
      assert_not context.to_prompt.key?("model_id")
      if relevance == "relevant"
        assert_includes context.query_terms, "NICE3000"
        assert_includes context.query_terms, "E51"
        assert_includes context.generation_block, "Photo Evidence for the active episode"
        assert_includes context.generation_block, "Not stated by the technician."
      else
        assert_empty context.query_terms
        assert_nil context.generation_block
      end
    end
  end

  test "a photo without an accepted observation is invalid and does not fall back" do
    create_photo(@account, observation(model: "OTHER"))
    photo = create_photo(@account, { "manufacturer" => "REJECTED-MFR" })
    context = Rag::ActivePhotoContext.resolve(episode: episode_with(photo.id), viewer_account: @account)

    assert_nil photo.visual_observation
    assert_equal "invalid", context.status
    assert_nil context.to_prompt
    assert_not_includes context.inspect, "OTHER"
    assert_not_includes context.inspect, "REJECTED-MFR"
  end

  test "nil relevance stays visible to the interpreter and out of retrieval" do
    photo = create_photo(@account, observation(relevance: nil, model: "NICE3000"))
    context = Rag::ActivePhotoContext.resolve(episode: episode_with(photo.id), viewer_account: @account)

    assert_nil context.to_prompt["relevance_to_goal"]
    assert_empty context.query_terms
    assert_nil context.generation_block
  end

  test "unknown values, the fingerprint, and the model id are omitted inside the byte cap" do
    photo = create_photo(@account, observation(
      relevance: "relevant",
      manufacturer: "UNKNOWN",
      model: "NICE3000",
      component: "C" * 80,
      codes: [ "E51", "UNKNOWN", "A2", "B3", "C4", "D5" ]
    ))
    context = Rag::ActivePhotoContext.resolve(episode: episode_with(photo.id), viewer_account: @account)
    prompt = context.to_prompt

    assert_equal 60, prompt["component"].length
    assert_not prompt.key?("manufacturer")
    assert_equal [ "E51", "A2", "B3", "C4" ], prompt["visible_text"]
    assert_operator JSON.generate(prompt).bytesize, :<=, Rag::ActivePhotoContext::MAX_BYTES
    assert_not_includes JSON.generate(prompt), "field_photos"
    assert_not_includes JSON.generate(prompt), photo.s3_key_original
  end

  private

  def episode_with(photo_id)
    episode = Rag::ActiveEpisode.open(correlation_id: "photo", now: @now)
    episode.active_photo = { "field_photo_id" => photo_id, "sha256" => "ab", "correlation_id" => "photo" }
    episode
  end

  def create_photo(account, raw)
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: account,
      sha256: sha,
      s3_key_original: "field_photos/#{account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg",
      byte_size: 8
    )
    photo.update!(visual_observation: raw) if raw["schema_version"] == 1 && raw["prompt_fingerprint"].present?
    photo.update!(visual_observation: raw) if raw.keys == [ "schema_version" ]
    if raw["prompt_fingerprint"].present?
      stored = FieldPhotoObservation.persist!(photo, raw)
      assert stored, raw.inspect
    end
    photo
  end

  def observation(relevance: nil, model: "NICE3000", manufacturer: "NICE", component: "controlador", codes: [ "E51" ])
    {
      "schema_version" => 1,
      "prompt_fingerprint" => "ab" * 32,
      "model_id" => "claude-sonnet-5-5",
      "canonical_component" => component,
      "manufacturer" => manufacturer,
      "model" => model,
      "subsystem" => "CONTROLLER_LOGIC",
      "condition" => "DEGRADED",
      "visible_text" => codes,
      "target_visible" => true,
      "relevance_to_goal" => relevance
    }
  end
end
