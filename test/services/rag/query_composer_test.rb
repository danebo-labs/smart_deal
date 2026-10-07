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

  test "a negate that consumes the turn is dropped while the prior goal stays in the query" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
    episode.assign_goal!("queda pasado de nivel", correlation_id: "seed")
    episode.append_observation!("pasa solo en planta 3", correlation_id: "seed")
    sentence = "No veo ningún código de falla"
    perception = report.with(
      move: "report",
      identities: [
        Rag::TurnPerception::Identity.new(
          span: sentence, act: "negate", kind: "negate", slot: nil,
          value: sentence, source: nil, manufacturer: nil
        )
      ]
    )

    explained = Rag::QueryComposer.explain(
      state: episode, turn: sentence, perception: perception, decision: decision_for("ready")
    )

    assert_includes explained[:query], "pasa solo en planta 3"
    assert_includes explained[:query], "queda pasado de nivel"
    assert_not_includes explained[:query], "código"
    assert_includes explained[:components], "current_turn:dropped"
    assert_includes explained[:components], "truncated:false"
    assert_equal explained[:query], Rag::QueryComposer.call(
      state: episode, turn: sentence, perception: perception, decision: decision_for("ready")
    )
  end

  test "a rejected 8 does not rewrite código 18 and a later turn still shows that code" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
    episode.write_fact!(
      "fault_code", status: "known", value: "18", source: "user",
      correlation_id: "seed", at: @now.iso8601
    )
    episode.append_rejected!("fault_code", "8")
    correction = "No, leí mal: era código 18, no 8."
    negate = Rag::TurnPerception::Identity.new(
      span: "8", act: "negate", kind: "negate", slot: "fault_code",
      value: "8", source: nil, manufacturer: nil
    )
    perception = report.with(move: "correct", identities: [ negate ])

    corrected = Rag::QueryComposer.call(
      state: episode, turn: correction, perception: perception, decision: decision_for("ready")
    )
    later = Rag::QueryComposer.call(
      state: episode, turn: "¿Y ahora?", perception: report, decision: decision_for("ready")
    )

    assert_includes corrected, "código 18"
    assert_not_includes corrected, "no ."
    assert_no_match(/(?<![[:alnum:]])código 8(?![[:alnum:]])/i, corrected)
    assert_no_match(/(?<![[:alnum:]])código 1(?![[:alnum:]])/i, corrected)
    assert_includes later, "código 18"
    assert_no_match(/(?<![[:alnum:]])código 1(?![[:alnum:]])/i, later)
  end

  test "a rejected fault code keeps LED 8 and a goal that mentions 8" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
    episode.assign_goal!("la puerta 8 no cierra", correlation_id: "seed")
    episode.write_fact!(
      "fault_code", status: "known", value: "18", source: "user",
      correlation_id: "seed", at: @now.iso8601
    )
    episode.append_rejected!("fault_code", "8")
    episode.append_observation!("El LED 8 está apagado", correlation_id: "seed")
    episode.append_observation!("El display muestra código 8", correlation_id: "seed")

    query = Rag::QueryComposer.call(
      state: episode,
      turn: "Era código 18, no 8. La guía no tiene obstrucción.",
      perception: report,
      decision: decision_for("ready")
    )

    assert_includes query, "código 18"
    assert_includes query, "El LED 8 está apagado"
    assert_includes query, "la puerta 8 no cierra"
    assert_includes query, "La guía no tiene obstrucción"
    assert_not_includes query, "no ."
    assert_not_includes query, "código 8"
  end

  test "the first turn does not repeat a phrase already said in that turn" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
    turn = "Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?"
    episode.assign_goal!("la puerta 1 no termina de cerrar el imán no magnetiza", correlation_id: "seed")
    episode.append_identifier!("Elemont MH", correlation_id: "seed")
    episode.append_identifier!("CEA15", correlation_id: "seed")
    episode.append_observation!("la puerta 1 no termina de cerrar", correlation_id: "seed")
    episode.append_observation!("el imán no magnetiza", correlation_id: "seed")

    query = Rag::QueryComposer.call(
      state: episode, turn: turn, perception: report, decision: decision_for("ready")
    )

    assert_equal 1, query.scan("la puerta 1 no termina de cerrar").size
    assert_equal 1, query.scan("el imán no magnetiza").size
    assert_equal 1, query.scan("Elemont MH").size
    assert_includes query, "CEA15"
  end

  test "session 195 still retrieves the code and the equipment when observations fill the cap" do
    raw = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/stage2_session_195.json").read)
    [ "12", "14" ].each do |turn|
      episode = episode_from_trace(raw.fetch(turn))
      query = Rag::QueryComposer.call(
        state: episode, turn: "¿Y ahora?", perception: report, decision: decision_for("ready")
      )

      assert_operator query.length, :<=, Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS
      assert_includes query, "código 18"
      assert_includes query, "Elemont MH"
      assert_includes query, "CEA15"
      assert_includes query, "la puerta 1 no termina de cerrar"
      assert_not_includes query, "Sigue igual"
      assert_not_includes query, "código 8"
    end
  end

  test "retained observations stay in the retrieval string" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
    kept = [
      "detenida cerca de planta 1",
      "no hay personas dentro",
      "comprobé visualmente la guía de la puerta",
      "se oye un clic, pero no termina de cerrar"
    ]
    kept.each { |text| episode.append_observation!(text, correlation_id: "seed") }

    query = Rag::QueryComposer.call(
      state: episode, turn: "¿Y ahora?", perception: report, decision: decision_for("ready")
    )

    kept.each { |text| assert_includes query, text }
  end

  test "meta and clarify_first compose no query and mark the turn dropped" do
    episode = Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
    explained = Rag::QueryComposer.explain(
      state: episode, turn: "Tengo una foto, ¿te sirve?", perception: report.with(move: "meta"),
      decision: decision_for("meta")
    )

    assert_nil explained[:query]
    assert_includes explained[:components], "current_turn:dropped"
    assert_includes explained[:components], "observations:0"
    assert_includes explained[:components], "truncated:false"
  end

  private

  def episode_from_trace(raw)
    Rag::ActiveEpisode.parse(
      {
        "v" => 1,
        "episode_id" => "ep_195",
        "status" => "active",
        "opened_at" => @now.iso8601,
        "updated_at" => @now.iso8601,
        "goal" => raw["goal"],
        "facts" => raw["facts"],
        "identifiers" => raw["identifiers"],
        "observations" => raw["observations"],
        "rejected" => raw["rejected"]
      },
      now: @now
    )
  end

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
