# frozen_string_literal: true

require "test_helper"

class ConversationSessionCaseBoundaryTest < ActiveSupport::TestCase
  NEW_CASE_PHRASE = "Ahora estoy revisando un KONE que no nivela en planta 3"
  CORRECTION_PHRASE = "No, no es Elemont. Es KONE"
  OPENING_PHRASE = "Cómo se ajustan los resortes de la fijación de cables ?"
  GOLDEN_PHRASE = "En las instrucciones de instalación del KONE MonoSpace Special para máquinas MX05, MX06 y MX10 con variadores V3F18, ¿cuál es la referencia del documento, la revisión y la fecha?"

  test "a new episode on a live case clears pins and procedure and keeps history" do
    session = web_session
    original_expires = session.expires_at
    elemont = manual("elemont-live.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    with_case_flags do
      session.record_user_turn!(OPENING_PHRASE, user_id: users(:one).id, correlation_id: "query:open")
      session.update!(
        current_procedure: { "step" => 3 },
        active_episode: session.active_episode.merge(
          "active_photo" => { "field_photo_id" => 9, "sha256" => "old", "correlation_id" => "photo:old" },
          "pending_fact" => { "subject" => "model", "correlation_id" => "query:pending" }
        )
      )
      session.pin_kb_document!(elemont)
      previous_id = session.reload.active_episode["episode_id"]

      result = session.record_user_turn!(NEW_CASE_PHRASE, user_id: users(:one).id, correlation_id: "query:new")

      session.reload
      assert_equal :new_episode, result.decision
      assert_not_equal previous_id, session.active_episode["episode_id"]
      assert_empty session.active_entities
      assert_equal({}, session.current_procedure)
      assert_nil session.active_episode["active_photo"]
      assert_nil session.active_episode["pending_fact"]
      assert_equal [ OPENING_PHRASE, NEW_CASE_PHRASE ], session.conversation_history.pluck("content")
      assert_operator session.expires_at, :>=, original_expires
      assert_empty SessionContextBuilder.entity_s3_uris(session)
      assert_equal "open", retrieval_scope([]).reason
    end
  end

  test "an Elemont to KONE correction releases only the incompatible pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-correct.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    generic = manual("generic-correct.pdf", "Procedimiento de engrase")
    both = manual("both-correct.pdf", "Elemont KONE referencia")
    procedure = { "step" => 2 }

    travel_to(at) do
      with_case_flags do
        seed_episode(session, episode_id: "ep_elemont", at: at, facts: { "manufacturer" => manufacturer_fact("Elemont", at) }, procedure: procedure)
        session.pin_kb_document!(elemont)
        session.pin_kb_document!(generic)
        session.pin_kb_document!(both)
        result = session.record_user_turn!(CORRECTION_PHRASE, user_id: users(:one).id, correlation_id: "query:correct")

        session.reload
        assert_equal :corrected, result.decision
        assert_equal "ep_elemont", session.active_episode["episode_id"]
        assert_nil session.find_entity_by_kb_document_id(elemont.id)
        assert session.find_entity_by_kb_document_id(generic.id)
        assert session.find_entity_by_kb_document_id(both.id)
        assert_equal procedure, session.current_procedure
        assert_not_includes SessionContextBuilder.entity_s3_uris(session), elemont.display_s3_uri(KbDocument::KB_BUCKET)
        assert_equal "pin_only", retrieval_scope(SessionContextBuilder.entity_s3_uris(session)).reason
      end
    end
  end

  test "an Elemont-only pin becomes an open retrieve after the manufacturer correction" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-only.pdf", "Elemont Montacargas Hidraulico Modelo MH")

    travel_to(at) do
      with_case_flags do
        seed_episode(session, episode_id: "ep_only", at: at, facts: { "manufacturer" => manufacturer_fact("Elemont", at) })
        session.pin_kb_document!(elemont)
        result = session.record_user_turn!(CORRECTION_PHRASE, user_id: users(:one).id, correlation_id: "query:only")

        session.reload
        assert_equal :corrected, result.decision
        assert_equal "ep_only", session.active_episode["episode_id"]
        assert_empty session.active_entities
        assert_empty SessionContextBuilder.entity_s3_uris(session)
        scope = retrieval_scope([])
        assert_equal "open", scope.reason
        assert_equal false, scope.force_entity_filter
      end
    end
  end

  test "No, es MiniSpace keeps a MonoSpace pin and a generic KONE pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    monospace = manual("kone-monospace.pdf", "KONE MonoSpace Special")
    generic = manual("kone-generic.pdf", "KONE")

    travel_to(at) do
      with_case_flags do
        seed_episode(
          session,
          episode_id: "ep_kone",
          at: at,
          facts: {
            "manufacturer" => manufacturer_fact("KONE", at),
            "model" => { "status" => "known", "value" => "MonoSpace", "source" => "user", "correlation_id" => "seed", "at" => at.iso8601 }
          }
        )
        session.pin_kb_document!(monospace)
        session.pin_kb_document!(generic)
        result = session.record_user_turn!("No, es MiniSpace", user_id: users(:one).id, correlation_id: "query:mini")

        session.reload
        assert_not_equal :new_episode, result.decision
        assert_equal "ep_kone", session.active_episode["episode_id"]
        assert session.find_entity_by_kb_document_id(monospace.id)
        assert session.find_entity_by_kb_document_id(generic.id)
        assert_equal "pin_only", retrieval_scope(SessionContextBuilder.entity_s3_uris(session)).reason
        assert_equal true, retrieval_scope(SessionContextBuilder.entity_s3_uris(session)).force_entity_filter
      end
    end
  end

  test "a continued mention and K1 keep the pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-k1.pdf", "Elemont Montacargas Hidraulico Modelo MH")

    travel_to(at) do
      with_case_flags do
        seed_episode(session, episode_id: "ep_k1", at: at, facts: { "manufacturer" => manufacturer_fact("Elemont", at) })
        session.pin_kb_document!(elemont)
        mention = session.record_user_turn!("¿es igual que en el KONE?", user_id: users(:one).id, correlation_id: "query:mention")
        follow = session.record_user_turn!("K1", user_id: users(:one).id, correlation_id: "query:k1")

        session.reload
        assert_equal :continued_mention, mention.decision
        assert_not_equal :new_episode, follow.decision
        assert_not_equal :corrected, follow.decision
        assert_equal "ep_k1", session.active_episode["episode_id"]
        assert session.find_entity_by_kb_document_id(elemont.id)
        uris = SessionContextBuilder.entity_s3_uris(session)
        assert_includes uris, elemont.display_s3_uri(KbDocument::KB_BUCKET)
        assert_equal "pin_only", retrieval_scope(uris).reason
      end
    end
  end

  test "a golden KONE question on a live Elemont episode keeps the pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-golden.pdf", "Elemont Montacargas Hidraulico Modelo MH")

    travel_to(at) do
      with_case_flags do
        seed_episode(session, episode_id: "ep_golden", at: at, facts: { "manufacturer" => manufacturer_fact("Elemont", at) })
        session.pin_kb_document!(elemont)
        result = session.record_user_turn!(GOLDEN_PHRASE, user_id: users(:one).id, correlation_id: "query:golden")

        session.reload
        assert_equal :continued_mention, result.decision
        assert_equal "ep_golden", session.active_episode["episode_id"]
        assert_includes SessionContextBuilder.entity_s3_uris(session), elemont.display_s3_uri(KbDocument::KB_BUCKET)
      end
    end
  end

  test "one hour later is still the same case and the pin stays" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-hour.pdf", "Elemont Montacargas Hidraulico Modelo MH")

    with_case_flags do
      travel_to(at) do
        seed_episode(session, episode_id: "ep_hour", at: at, facts: { "manufacturer" => manufacturer_fact("Elemont", at) })
        session.pin_kb_document!(elemont)
      end
      travel_to(at + 1.hour) do
        result = session.record_user_turn!("K1", user_id: users(:one).id, correlation_id: "query:hour", now: Time.current)
        session.reload
        assert_not_equal :new_episode, result.decision
        assert_equal "ep_hour", session.active_episode["episode_id"]
        assert session.find_entity_by_kb_document_id(elemont.id)
      end
    end
  end

  test "hola after expiry clears the old pin and a later query sees no entity uri" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-hola.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    original_expires = nil

    with_case_flags do
      travel_to(at) do
        session.update!(expires_at: 30.days.from_now)
        seed_episode(session, episode_id: "ep_expired", at: at, facts: { "manufacturer" => manufacturer_fact("Elemont", at) }, procedure: { "step" => 4 })
        session.pin_kb_document!(elemont)
        original_expires = session.reload.expires_at
      end
      travel_to(at + ConversationSession::EPISODE_WINDOW + 1.second) do
        result = session.record_user_turn!("hola", user_id: users(:one).id, correlation_id: "query:hola", now: Time.current)
        session.reload
        assert_equal :no_episode, result.decision
        assert_empty session.active_entities
        assert_equal({}, session.current_procedure)
        assert_equal({}, session.active_episode)
        assert_empty SessionContextBuilder.entity_s3_uris(session)
        assert_equal "open", retrieval_scope([]).reason
        assert_equal false, retrieval_scope([]).force_entity_filter
        assert_operator session.expires_at, :>=, original_expires
        assert_equal session.id, ConversationSession.find(session.id).id
      end
    end
  end

  test "an opening question after expiry clears the old pin and opens a new case" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-open.pdf", "Elemont Montacargas Hidraulico Modelo MH")

    with_case_flags do
      travel_to(at) do
        seed_episode(session, episode_id: "ep_before_open", at: at, procedure: { "step" => 2 })
        session.pin_kb_document!(elemont)
      end
      travel_to(at + ConversationSession::EPISODE_WINDOW + 1.second) do
        result = session.record_user_turn!(OPENING_PHRASE, user_id: users(:one).id, correlation_id: "query:reopen", now: Time.current)
        session.reload
        assert_equal :opened, result.decision
        assert_not_equal "ep_before_open", session.active_episode["episode_id"]
        assert session.active_episode["episode_id"].present?
        assert_empty session.active_entities
        assert_equal({}, session.current_procedure)
        assert_empty SessionContextBuilder.entity_s3_uris(session)
      end
    end
  end

  test "a reset phrase on an expired case uses the expiry cutoff instead of wiping every pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    during = manual("reset-during.pdf", "Elemont durante el caso")
    after = manual("reset-after.pdf", "Manual posterior al vencimiento")
    cutoff = at + ConversationSession::EPISODE_WINDOW

    with_case_flags do
      travel_to(at) { seed_episode(session, episode_id: "ep_reset_expired", at: at) }
      session.update!(active_entities: {
        during.display_name => pin_entity(during, at + 20.seconds),
        after.display_name => pin_entity(after, cutoff + 5.seconds)
      })
      travel_to(cutoff + 1.second) do
        result = session.record_user_turn!(
          "otra falla en el tablero principal",
          user_id: users(:one).id,
          correlation_id: "query:reset-expired",
          now: Time.current
        )
        session.reload
        assert_equal :new_episode, result.decision
        assert_not_equal "ep_reset_expired", session.active_episode["episode_id"]
        assert_nil session.find_entity_by_kb_document_id(during.id)
        assert session.find_entity_by_kb_document_id(after.id)
      end
    end
  end

  test "a skipped turn after expiry also clears pins of the expired case" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-skip.pdf", "Elemont Montacargas Hidraulico Modelo MH")

    with_case_flags do
      travel_to(at) do
        seed_episode(session, episode_id: "ep_skip", at: at, procedure: { "step" => 1 })
        session.pin_kb_document!(elemont)
      end
      travel_to(at + ConversationSession::EPISODE_WINDOW + 1.second) do
        result = session.record_user_turn!(
          "Elemont",
          user_id: users(:one).id,
          correlation_id: "query:skip",
          selection_turn: true,
          now: Time.current
        )
        session.reload
        assert_equal :skipped, result.decision
        assert_empty session.active_entities
        assert_equal({}, session.current_procedure)
      end
    end
  end

  test "expiry keeps only a pin added after the case window" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    during = manual("during.pdf", "Elemont durante")
    after = manual("after-window.pdf", "Manual posterior")
    missing = manual("missing-added.pdf", "Sin marca de tiempo")
    invalid = manual("invalid-added.pdf", "Fecha invalida")
    cutoff = at + ConversationSession::EPISODE_WINDOW

    with_case_flags do
      travel_to(at) do
        seed_episode(session, episode_id: "ep_cut", at: at, procedure: { "step" => 8 })
      end
      session.update!(active_entities: {
        during.display_name => pin_entity(during, at + 20.seconds),
        after.display_name => pin_entity(after, cutoff + 5.seconds),
        missing.display_name => pin_entity(missing, nil),
        invalid.display_name => pin_entity(invalid, nil).merge("added_at" => "not-a-timestamp")
      })

      travel_to(cutoff + 1.second) do
        session.record_user_turn!("hola", user_id: users(:one).id, correlation_id: "query:cut", now: Time.current)
      end

      session.reload
      assert_nil session.find_entity_by_kb_document_id(during.id)
      assert_nil session.find_entity_by_kb_document_id(missing.id)
      assert_nil session.find_entity_by_kb_document_id(invalid.id)
      assert session.find_entity_by_kb_document_id(after.id)
      assert_equal [ after.display_s3_uri(KbDocument::KB_BUCKET) ], SessionContextBuilder.entity_s3_uris(session)
      assert_equal({}, session.current_procedure)
    end
  end

  test "an explicit re-pin after expiry renews added_at and survives the cleanup" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    renewed = manual("renewed.pdf", "Elemont renovado")
    stale = manual("stale-sibling.pdf", "Elemont hermano")
    expiry = at + ConversationSession::EPISODE_WINDOW + 1.second

    with_case_flags do
      travel_to(at) do
        seed_episode(session, episode_id: "ep_renew", at: at)
        session.pin_kb_document!(renewed)
        session.pin_kb_document!(stale)
      end
      travel_to(expiry) do
        assert session.pin_kb_document!(renewed)
        session.record_user_turn!("hola", user_id: users(:one).id, correlation_id: "query:renew", now: Time.current)
      end

      session.reload
      assert_nil session.find_entity_by_kb_document_id(stale.id)
      kept = session.active_entities.values.find { |meta| meta["kb_document_id"] == renewed.id }
      assert kept
      assert_equal expiry.to_i, Time.zone.parse(kept["added_at"]).to_i
      assert_equal renewed.display_s3_uri(KbDocument::KB_BUCKET), kept["source_uri"]
    end
  end

  test "the first opened turn from an empty episode keeps a fresh pin" do
    session = web_session
    elemont = manual("fresh-pin.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    session.update!(current_procedure: { "step" => 1 })
    session.pin_kb_document!(elemont)

    with_case_flags do
      result = session.record_user_turn!(OPENING_PHRASE, user_id: users(:one).id, correlation_id: "query:first")
      session.reload
      assert_equal :opened, result.decision
      assert session.find_entity_by_kb_document_id(elemont.id)
      assert_equal({ "step" => 1 }, session.current_procedure)
      assert_includes SessionContextBuilder.entity_s3_uris(session), elemont.display_s3_uri(KbDocument::KB_BUCKET)
    end
  end

  test "a stale in-memory pin set cannot resurrect pins cleared by expiry" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    kept = manual("race-kept.pdf", "Manual que se vuelve a pinear")
    cleared = manual("race-cleared.pdf", "Manual que no debe volver")

    with_case_flags do
      travel_to(at) do
        seed_episode(session, episode_id: "ep_race", at: at)
        session.pin_kb_document!(kept)
        session.pin_kb_document!(cleared)
      end
      stale = ConversationSession.find(session.id)
      assert_equal 2, stale.active_entities.size

      travel_to(at + ConversationSession::EPISODE_WINDOW + 1.second) do
        session.record_user_turn!("hola", user_id: users(:one).id, correlation_id: "query:race", now: Time.current)
        assert_empty session.reload.active_entities
        assert stale.pin_kb_document!(kept)
      end

      reloaded = ConversationSession.find(session.id)
      assert_equal 1, reloaded.entity_count
      assert reloaded.find_entity_by_kb_document_id(kept.id)
      assert_nil reloaded.find_entity_by_kb_document_id(cleared.id)
    end
  end

  test "start_new_case! clears pins and procedure without touching history or the row" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    doc = manual("explicit.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    travel_to(at) do
      seed_episode(session, episode_id: "ep_explicit", at: at, procedure: { "step" => 5 })
      session.pin_kb_document!(doc)
      session.update!(conversation_history: [ { "role" => "user", "content" => "antes", "ts" => at.iso8601 } ])
    end
    expires = session.reload.expires_at
    row_id = session.id

    travel_to(at + 5.minutes) do
      new_id = session.start_new_case!(now: Time.current, reason: "explicit_new_case", correlation_id: "case:new")
      session.reload
      assert_equal new_id, session.active_episode["episode_id"]
      assert_not_equal "ep_explicit", new_id
      assert_empty session.active_entities
      assert_equal({}, session.current_procedure)
      assert_equal [ "antes" ], session.conversation_history.pluck("content")
      assert_equal expires.to_i, session.expires_at.to_i
      assert_equal row_id, session.id
    end
  end

  private

  def web_session
    ConversationSession.create!(
      identifier: "web:boundary:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: users(:one),
      account: accounts(:legacy)
    )
  end

  def manual(key, name)
    KbDocument.create!(
      s3_key: "uploads/2026/boundary/#{key}",
      display_name: name,
      aliases: [],
      account: accounts(:legacy)
    )
  end

  def manufacturer_fact(value, at)
    { "status" => "known", "value" => value, "source" => "user", "correlation_id" => "seed", "at" => at.iso8601 }
  end

  def seed_episode(session, episode_id:, at:, facts: {}, procedure: {})
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
      },
      current_procedure: procedure
    )
  end

  def pin_entity(doc, added_at)
    entity = {
      "canonical_name" => doc.display_name,
      "kb_document_id" => doc.id,
      "source" => "user_pin",
      "source_uri" => doc.display_s3_uri(KbDocument::KB_BUCKET),
      "aliases" => []
    }
    entity["added_at"] = added_at.iso8601 if added_at
    entity
  end

  def with_case_flags
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") { yield }
      end
    end
  end

  def retrieval_scope(uris)
    Object.new.extend(RagQueryConcern).send(:resolve_retrieval_scope, pinned_uris: uris)
  end
end
