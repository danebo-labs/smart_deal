# frozen_string_literal: true

require "test_helper"

class Rag::QueryComposerTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:legacy)
    @now = Time.current
  end

  test "relevant photo terms are composed and the other relevances are not" do
    [ "relevant", "uncertain", "unrelated", nil ].each do |relevance|
      photo = create_photo(relevance)
      episode = episode_for(photo)
      context = Rag::ActivePhotoContext.resolve(episode: episode, viewer_account: @account)
      decision = decision_for("ready")
      query = Rag::QueryComposer.call(
        state: episode, turn: "¿Qué reviso ahora?", perception: report, decision: decision,
        active_photo_context: context
      )

      if relevance == "relevant"
        assert_includes query, "NICE3000"
        assert_includes query, "E51"
      else
        assert_not_includes query.to_s, "OTIS2000"
        assert_not_includes query.to_s, "ZZ9"
      end
      assert_operator query.to_s.length, :<=, Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS
    end
  end

  test "a remembered photo identity stays in the query when the active photo is not relevant" do
    photo = create_photo("uncertain")
    episode = episode_for(photo)
    episode.write_fact!(
      "model", status: "known", value: "NICE3000", source: "photo",
      correlation_id: "seed", at: @now.iso8601
    )
    context = Rag::ActivePhotoContext.resolve(episode: episode, viewer_account: @account)
    query = Rag::QueryComposer.call(
      state: episode, turn: "¿Qué reviso ahora?", perception: report, decision: decision_for("ready"),
      active_photo_context: context
    )

    assert_includes query, "NICE3000"
    assert_not_includes query, "OTIS2000"
    assert_not_includes query, "ZZ9"
  end

  test "an invalid active photo adds no retrieval terms" do
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: @account, sha256: sha, s3_key_original: "field_photos/#{@account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 8,
      visual_observation: { "manufacturer" => "REJECTED-MFR", "model" => "SECRETMODEL", "visible_text" => [ "CODE-NEW" ] }
    )
    episode = episode_for(photo)
    context = Rag::ActivePhotoContext.resolve(episode: episode, viewer_account: @account)
    query = Rag::QueryComposer.call(
      state: episode, turn: "¿Qué reviso ahora?", perception: report, decision: decision_for("ready"),
      active_photo_context: context
    )

    assert_equal "invalid", context.status
    assert_not_includes query.to_s, "REJECTED-MFR"
    assert_not_includes query.to_s, "SECRETMODEL"
    assert_not_includes query.to_s, "CODE-NEW"
  end

  test "photo terms are dropped when the photo id no longer matches or the route does not retrieve" do
    photo = create_photo("relevant")
    episode = episode_for(photo)
    context = Rag::ActivePhotoContext.resolve(episode: episode, viewer_account: @account)
    episode.active_photo = nil
    ready = Rag::QueryComposer.call(
      state: episode, turn: "¿Qué reviso ahora?", perception: report, decision: decision_for("ready"),
      active_photo_context: context
    )
    clarify = Rag::QueryComposer.call(
      state: episode_for(photo), turn: "¿Qué reviso ahora?", perception: report, decision: decision_for("clarify_first"),
      active_photo_context: context
    )

    assert_not_includes ready.to_s, "NICE3000"
    assert_nil clarify
  end

  private

  def episode_for(photo)
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
    episode.assign_goal!("¿Qué reviso ahora?", correlation_id: "seed")
    episode.active_photo = { "field_photo_id" => photo.id, "sha256" => photo.sha256, "correlation_id" => "photo" }
    episode
  end

  def report
    Rag::TurnPerception::Result.new(
      valid: true, move: "follow_up", observations: [], pending_resolution: nil, clarification_target: nil,
      identities: [], ambiguities: [], field_rejections: [], catalog_disagreements: [], invalid_reason: nil
    )
  end

  def decision_for(name)
    Rag::RoutePolicy::Decision.new(
      decision: name, retrieval_query: nil, clarification: nil, pending_subject: nil,
      outside_discovery: false, owns_query: name == "ready", bare_identifier: nil, ask_when: nil,
      mutations: [], dialogue_function: "follow_up", context_carry: false, focus_uris: [],
      focus_document_ids: [], pending_question: nil, fallback: false
    )
  end

  def create_photo(relevance)
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: @account, sha256: sha, s3_key_original: "field_photos/#{@account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 8
    )
    model = relevance == "relevant" ? "NICE3000" : "OTIS2000"
    code = relevance == "relevant" ? "E51" : "ZZ9"
    FieldPhotoObservation.persist!(photo, {
      "schema_version" => 1,
      "prompt_fingerprint" => "ab" * 32,
      "model_id" => "claude-sonnet-5-5",
      "canonical_component" => "controlador",
      "manufacturer" => relevance == "relevant" ? "NICE" : "OTIS",
      "model" => model,
      "subsystem" => "CONTROLLER_LOGIC",
      "condition" => "GOOD",
      "visible_text" => [ code ],
      "target_visible" => true,
      "relevance_to_goal" => relevance
    })
    photo
  end
end
