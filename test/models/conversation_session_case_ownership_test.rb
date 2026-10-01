# frozen_string_literal: true

require "test_helper"

class ConversationSessionCaseOwnershipTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  OPENING = "Cómo se ajustan los resortes de la fijación de cables ?"
  NEW_CASE = "Ahora estoy revisando un KONE que no nivela en planta 3"
  CORRECTION = "No, no es Elemont. Es KONE"

  setup do
    clear_enqueued_jobs
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "a late text writer from case A does not modify case B" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    reply = "En el manual, página 12. ¿Sabes el modelo del equipo?"

    travel_to(at) do
      with_case_flags do
        events = capture_case_logs do
          session.record_user_turn!(OPENING, user_id: users(:one).id, correlation_id: "query:a")
          owner = session.live_episode_id
          session.record_user_turn!(NEW_CASE, user_id: users(:one).id, correlation_id: "query:b")
          later = session.reload.active_episode
          result = session.record_assistant_turn!(
            reply, user_id: users(:one).id, correlation_id: "query:late", expected_episode_id: owner
          )

          session.reload
          assert_nil result
          assert_equal later["episode_id"], session.active_episode["episode_id"]
          assert_equal later["facts"], session.active_episode["facts"]
          assert_nil session.active_episode["pending_fact"]
          assert_equal [ OPENING, NEW_CASE ], session.conversation_history.pluck("content")
        end

        dropped = events.find { |event| event["event"] == "stale_case_write_dropped" && event["writer"] == "assistant" }
        assert_equal true, dropped["dropped"]
        assert_equal session.id, dropped["conversation_session_id"]
        assert dropped["expected_episode_id"].present?
        assert_not_equal dropped["expected_episode_id"], dropped["current_episode_id"]
        assert_equal "query:late", dropped["correlation_id"]
        assert_not_includes JSON.generate(dropped), reply
      end
    end
  end

  test "a late photo writer from case A does not modify case B" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    reply = "[FOTO] Fabricante: OTIS"

    travel_to(at) do
      with_case_flags do
        events = capture_case_logs do
          session.record_user_turn!(OPENING, user_id: users(:one).id, correlation_id: "query:a")
          owner = session.live_episode_id
          session.record_user_turn!(NEW_CASE, user_id: users(:one).id, correlation_id: "query:b")
          later_id = session.live_episode_id
          session.record_photo_observation!(
            photo_value: photo_reading("OTIS", "Gen2"),
            field_photo_id: 77,
            sha256: "late-photo",
            correlation_id: "photo:late",
            expected_episode_id: owner
          )
          session.record_assistant_turn!(
            reply,
            user_id: users(:one).id,
            correlation_id: "photo:late",
            expected_episode_id: owner,
            writer: "photo_assistant"
          )

          episode = session.reload.active_episode
          assert_equal later_id, episode["episode_id"]
          assert_nil episode["active_photo"]
          assert_nil episode.dig("facts", "model")
          assert_not_equal "OTIS", episode.dig("facts", "manufacturer", "value")
          assert_not_includes session.conversation_history.pluck("content"), reply
        end

        writers = events.select { |event| event["event"] == "stale_case_write_dropped" }.pluck("writer")
        assert_includes writers, "photo_observation"
        assert_includes writers, "photo_assistant"
      end
    end
  end

  test "a photo submission opens and persists a case before the job is enqueued" do
    session = web_session
    image = { data: Base64.strict_encode64("jpeg-bytes"), media_type: "image/jpeg", filename: "panel.jpg" }

    with_case_flags do
      assert_nil session.live_episode_id
      QueryOrchestratorService.new(
        "",
        images: [ image ],
        account: accounts(:legacy),
        conv_session: session,
        user_id: users(:one).id
      ).execute

      owner = session.reload.live_episode_id
      args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
      assert owner.present?
      assert_equal owner, args["expected_episode_id"]
      assert_nil session.active_episode["active_photo"]

      session.record_user_turn!("el modelo es MonoSpace", user_id: users(:one).id, correlation_id: "query:follow")
      assert_equal owner, session.live_episode_id
      session.record_photo_observation!(
        photo_value: photo_reading("KONE", "MonoSpace"),
        field_photo_id: 8,
        sha256: "same-case",
        correlation_id: "photo:same",
        expected_episode_id: owner
      )
      assert_equal "same-case", session.reload.active_episode.dig("active_photo", "sha256")
      assert_equal "MonoSpace", session.active_episode.dig("facts", "model", "value")
    end
  end

  test "reuse and reread keep the case opened for that photo submission" do
    session = web_session
    photo = FieldPhoto.create!(
      account_id: accounts(:legacy).id, sha256: "r" * 64,
      s3_key_original: "field_photos/#{accounts(:legacy).id}/#{'r' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )

    with_case_flags do
      owner = session.ensure_case_for_photo_submission!(correlation_id: "photo:stored")
      QueryOrchestratorService.new(
        "revisa otra vez la foto",
        account: accounts(:legacy),
        conv_session: session,
        field_photo_id: photo.id,
        user_id: users(:one).id
      ).execute

      args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
      assert_equal "reread", args["continuity"]
      assert_equal owner, args["expected_episode_id"]
      assert_equal owner, session.reload.live_episode_id
    end
  end

  test "the episode flag off does not open a case for a photo submission" do
    session = web_session
    image = { data: Base64.strict_encode64("jpeg-bytes"), media_type: "image/jpeg", filename: "panel.jpg" }

    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "false") do
      QueryOrchestratorService.new(
        "",
        images: [ image ],
        account: accounts(:legacy),
        conv_session: session,
        user_id: users(:one).id
      ).execute
    end

    args = enqueued_jobs.find { |job| job[:job] == FieldPhotoAnalysisJob }[:args].first
    assert_nil args["expected_episode_id"]
    assert_equal({}, session.reload.active_episode)
  end

  test "an expired photo submission opens a new case and keeps the selected manual" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-photo.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    travel_to(at) do
      seed_episode(session, "ep_old", at)
      session.update!(
        current_procedure: { "step" => 4 },
        document_focus: [ {
          "kb_document_id" => elemont.id,
          "source_uri" => elemont.display_s3_uri(KbDocument::KB_BUCKET),
          "display_name" => elemont.display_name,
          "added_at" => at.iso8601
        } ],
        active_episode: session.active_episode.merge(
          "active_photo" => { "field_photo_id" => 3, "sha256" => "old-photo" }
        )
      )
    end

    travel_to(at + ConversationSession::EPISODE_WINDOW + 1.second) do
      with_case_flags do
        owner = session.ensure_case_for_photo_submission!(correlation_id: "photo:new")
        session.reload
        assert_not_equal "ep_old", owner
        assert_equal owner, session.live_episode_id
        assert session.find_entity_by_kb_document_id(elemont.id)
        assert_equal 1, session.document_focus_entries.size
        assert_equal({}, session.current_procedure)
        assert_nil session.active_episode["active_photo"]
        assert_includes SessionContextBuilder.entity_s3_uris(session), elemont.display_s3_uri(KbDocument::KB_BUCKET)

        session.record_photo_observation!(
          photo_value: photo_reading("KONE", "MonoSpace"),
          field_photo_id: 11,
          sha256: "new-photo",
          correlation_id: "photo:new",
          expected_episode_id: owner
        )
        episode = session.reload.active_episode
        assert_equal owner, episode["episode_id"]
        assert_equal "new-photo", episode.dig("active_photo", "sha256")
        assert_equal "KONE", episode.dig("facts", "manufacturer", "value")
        assert_equal "photo", episode.dig("facts", "manufacturer", "source")
        assert_equal "MonoSpace", episode.dig("facts", "model", "value")
        assert session.find_entity_by_kb_document_id(elemont.id)
        assert_equal 1, session.document_focus_entries.size
      end
    end
  end

  test "a same-episode assistant turn keeps the pin after a manufacturer correction" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-assist.pdf", "Elemont Montacargas Hidraulico Modelo MH")

    travel_to(at) do
      with_case_flags do
        seed_episode(
          session, "ep_elemont", at,
          facts: { "manufacturer" => { "status" => "known", "value" => "Elemont", "source" => "user", "correlation_id" => "seed", "at" => at.iso8601 } }
        )
        session.pin_kb_document!(elemont)
        result = session.record_user_turn!(CORRECTION, user_id: users(:one).id, correlation_id: "query:correct")
        assert_equal :corrected, result.decision
        assert_equal "KONE", session.reload.active_episode.dig("facts", "manufacturer", "value")
        assert session.find_entity_by_kb_document_id(elemont.id)

        session.record_assistant_turn!(
          "Reviso el manual KONE. ¿Sabes el modelo?",
          user_id: users(:one).id,
          correlation_id: "query:answer",
          expected_episode_id: "ep_elemont"
        )

        session.reload
        assert_equal "ep_elemont", session.active_episode["episode_id"]
        assert session.find_entity_by_kb_document_id(elemont.id)
        assert_equal 1, session.document_focus_entries.size
        assert_includes SessionContextBuilder.entity_s3_uris(session), elemont.display_s3_uri(KbDocument::KB_BUCKET)
        assert_equal "model", session.active_episode.dig("pending_fact", "subject")
      end
    end
  end

  test "history readers stop at the live episode opened_at and keep the stored rows" do
    at = Time.zone.parse("2026-09-30 14:00:00")
    opened = at - 10.minutes
    session = web_session
    session.update!(
      conversation_history: [
        { "role" => "user", "content" => "pregunta vieja del caso anterior", "ts" => (opened - 1.minute).iso8601, "correlation_id" => "query:old" },
        { "role" => "assistant", "content" => "respuesta vieja", "ts" => (opened - 30.seconds).iso8601, "correlation_id" => "query:old" },
        { "role" => "user", "content" => "pregunta de este caso", "ts" => opened.iso8601, "correlation_id" => "query:new" },
        { "role" => "assistant", "content" => "respuesta de este caso", "ts" => (opened + 1.minute).iso8601, "correlation_id" => "query:new" }
      ],
      active_episode: {
        "v" => 1, "episode_id" => "ep_floor", "status" => "active",
        "opened_at" => opened.iso8601, "updated_at" => at.iso8601,
        "facts" => {}, "identifiers" => [], "conflicts" => []
      }
    )

    travel_to(at) do
      assert_equal [ "pregunta de este caso" ], session.recent_user_turns(at).pluck("content")
      assert_equal [ "pregunta de este caso" ], session.episode_user_messages(now: at)
      assert_equal "respuesta de este caso", session.last_assistant_message(now: at)
      assert_equal 4, session.conversation_history.size

      session.update!(
        conversation_history: [
          { "role" => "user", "content" => "Cómo se ajustan los resortes?", "ts" => (opened - 1.minute).iso8601, "correlation_id" => "query:old" },
          { "role" => "assistant", "content" => "respuesta vieja", "ts" => (opened - 30.seconds).iso8601, "correlation_id" => "query:old" },
          { "role" => "user", "content" => "K1", "ts" => at.iso8601, "correlation_id" => "query:k1" }
        ]
      )
      follow = Rag::FollowupQueryRewriter.call(
        question: "K1",
        conversation_session: session,
        account: accounts(:legacy),
        correlation_id: "query:k1",
        now: at
      )
      assert_equal "no_episode", follow.reason
      assert_equal false, follow.applied
      assert_includes session.conversation_history.pluck("content"), "Cómo se ajustan los resortes?"
    end
  end

  test "a document upload captures the live episode id and does not read it again later" do
    at = Time.zone.parse("2026-09-30 12:00:00")
    session = web_session
    document = { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: "manual.pdf" }

    travel_to(at) do
      with_case_flags do
        seed_episode(session, "ep_upload", at)
        QueryOrchestratorService.new(
          "",
          documents: [ document ],
          account: accounts(:legacy),
          conv_session: session,
          user_id: users(:one).id,
          document_uids: [ SecureRandom.uuid ]
        ).execute
        args = enqueued_jobs.find { |job| job[:job] == UploadAndSyncAttachmentsJob }[:args].first
        assert_equal "ep_upload", args["expected_episode_id"]

        session.start_new_case!(reason: "explicit_new_case", correlation_id: "case:later")
        assert_not_equal "ep_upload", session.reload.live_episode_id
        assert_equal "ep_upload", args["expected_episode_id"]
      end
    end
  end

  test "case probes record boundary and pin changes without the question text" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-probe.pdf", "Elemont Montacargas Hidraulico Modelo MH")

    travel_to(at) do
      with_case_flags do
        events = capture_case_logs do
          session.record_user_turn!(OPENING, user_id: users(:one).id, correlation_id: "query:open")
        end
        assert events.none? { |event| event["event"] == "R1B_CASE_PROBE" }

        session.update!(
          active_episode: session.active_episode.merge(
            "facts" => {
              "manufacturer" => {
                "status" => "known", "value" => "Elemont", "source" => "user",
                "correlation_id" => "seed", "at" => at.iso8601
              }
            }
          )
        )
        session.pin_kb_document!(elemont)
        episode_id = session.reload.active_episode["episode_id"]
        events = capture_case_logs do
          session.record_user_turn!(CORRECTION, user_id: users(:one).id, correlation_id: "query:correct")
        end
        assert events.none? { |event| event["event"] == "R1B_CASE_PROBE" }
        session.reload
        assert_equal "KONE", session.active_episode.dig("facts", "manufacturer", "value")
        assert_equal episode_id, session.active_episode["episode_id"]
        assert session.find_entity_by_kb_document_id(elemont.id)

        events = capture_case_logs do
          session.record_user_turn!(NEW_CASE, user_id: users(:one).id, correlation_id: "query:new")
        end
        opened = events.find { |event| event["event"] == "R1B_CASE_PROBE" }
        assert_equal "new_episode", opened["case_boundary_reason"]
        assert_nil opened["pin_release_reason"]
        assert_not_equal opened["episode_before"], opened["episode_after"]
        assert_includes opened["pins_before"], elemont.id
        assert_includes opened["pins_after"], elemont.id
        assert session.reload.find_entity_by_kb_document_id(elemont.id)
      end
    end
  end

  private

  def web_session
    ConversationSession.create!(
      identifier: "web:owner:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: users(:one),
      account: accounts(:legacy)
    )
  end

  def manual(key, name)
    KbDocument.create!(
      s3_key: "uploads/2026/owner/#{key}",
      display_name: name,
      aliases: [],
      account: accounts(:legacy)
    )
  end

  def seed_episode(session, episode_id, at, facts: {})
    session.update!(
      active_episode: {
        "v" => 1,
        "episode_id" => episode_id,
        "status" => "active",
        "opened_at" => at.iso8601,
        "updated_at" => at.iso8601,
        "facts" => facts,
        "identifiers" => [],
        "conflicts" => []
      }
    )
  end

  def photo_reading(manufacturer, model)
    {
      manufacturer: manufacturer,
      model_visible: model,
      target_visible: true,
      relevance_to_goal: "relevant"
    }
  end

  def with_case_flags
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") { yield }
      end
    end
  end

  def capture_case_logs
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    output.string.lines.filter_map do |line|
      start = line.index("{")
      next unless start

      parsed = JSON.parse(line[start..])
      parsed if parsed.is_a?(Hash) && parsed["event"].present?
    rescue JSON::ParserError
      nil
    end
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end
