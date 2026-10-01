# frozen_string_literal: true

require "test_helper"

class ConversationSessionConditionalManufacturerTest < ActiveSupport::TestCase
  CORRECTION = "No, no es Elemont. Es KONE"
  AMBIGUOUS = "No es Elemont, puede ser KONE u OTIS"
  MODEL_CORRECTION = "No, es MiniSpace"
  SINGLE_BRAND = "En realidad es KONE"
  GOAL = "ajuste de resortes"

  test "conditional Elemont to KONE correction writes KONE and keeps every pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-conditional.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    neutral = manual("neutral-conditional.pdf", "Procedimiento de engrase")
    analysis = correction_analysis([ "Elemont", "equipment" ], [ "KONE", "equipment" ])

    travel_to(at) do
      with_episode_flags do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "conditional") do
          assert_equal "conditional", Rag::HaikuQueryAnalysisFlag.mode
          seed_case(session, at)
          session.pin_kb_document!(elemont)
          session.pin_kb_document!(neutral)

          calls = []
          events = capture_case_logs do
            calls = stub_ownership(analysis) do
              session.record_user_turn!(CORRECTION, user_id: users(:one).id, correlation_id: "query:correct")
            end
          end

          session.reload
          assert_equal [ CORRECTION ], calls
          assert_kone_correction(session, session_result: events)
          assert_equal "KONE", session.active_episode.dig("facts", "manufacturer", "value")
          assert_equal "user", session.active_episode.dig("facts", "manufacturer", "source")
          assert_equal "query:correct", session.active_episode.dig("facts", "manufacturer", "correlation_id")
          assert_equal at.iso8601, session.active_episode.dig("facts", "manufacturer", "at")
          assert_nil session.active_episode.dig("facts", "model")
          assert_nil session.active_episode["goal"]
          assert_equal [ "CEA15" ], session.active_episode["identifiers"].pluck("value")
          assert_equal [ "manufacturer" ], session.active_episode["conflicts"].pluck("fact")
          assert session.find_entity_by_kb_document_id(elemont.id)
          assert session.find_entity_by_kb_document_id(neutral.id)
          assert_equal 2, session.document_focus_entries.size
          uris = SessionContextBuilder.entity_s3_uris(session)
          assert_includes uris, elemont.display_s3_uri(KbDocument::KB_BUCKET)
          assert_includes uris, neutral.display_s3_uri(KbDocument::KB_BUCKET)
          refute_mismatch_release(events)
          slice = events.find { |event| event["event"] == "haiku_ownership_slice" }
          assert_equal "correct", slice["relation"]
          assert_equal true, slice["ownership_applied"]
        end
      end
    end
  end

  test "haiku off Elemont to KONE correction writes KONE and keeps every pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-off.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    neutral = manual("neutral-off.pdf", "Procedimiento de engrase")

    travel_to(at) do
      with_episode_flags do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") do
          assert_equal "off", Rag::HaikuQueryAnalysisFlag.mode
          seed_case(session, at)
          session.pin_kb_document!(elemont)
          session.pin_kb_document!(neutral)

          events = capture_case_logs do
            forbid_ownership do
              session.record_user_turn!(CORRECTION, user_id: users(:one).id, correlation_id: "query:correct")
            end
          end

          session.reload
          assert_equal :corrected, last_decision(events)
          assert_equal "ep_elemont", session.active_episode["episode_id"]
          assert_equal "KONE", session.active_episode.dig("facts", "manufacturer", "value")
          assert_equal "user", session.active_episode.dig("facts", "manufacturer", "source")
          assert_equal "query:correct", session.active_episode.dig("facts", "manufacturer", "correlation_id")
          assert_equal at.iso8601, session.active_episode.dig("facts", "manufacturer", "at")
          assert_nil session.active_episode.dig("facts", "model")
          assert_equal GOAL, session.active_episode.dig("goal", "text")
          assert_equal [], session.active_episode["identifiers"]
          assert_equal [], session.active_episode["conflicts"]
          assert session.find_entity_by_kb_document_id(elemont.id)
          assert session.find_entity_by_kb_document_id(neutral.id)
          assert_equal 2, session.document_focus_entries.size
          uris = SessionContextBuilder.entity_s3_uris(session)
          assert_includes uris, elemont.display_s3_uri(KbDocument::KB_BUCKET)
          assert_includes uris, neutral.display_s3_uri(KbDocument::KB_BUCKET)
          refute_mismatch_release(events)
          assert events.none? { |event| event["event"] == "haiku_ownership_slice" }
        end
      end
    end
  end

  test "an ambiguous conditional correction does not invent a manufacturer or release the pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-ambiguous.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    analysis = correction_analysis(
      [ "Elemont", "equipment" ],
      [ "KONE", "equipment" ],
      [ "OTIS", "equipment" ]
    )

    travel_to(at) do
      with_episode_flags do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "conditional") do
          seed_case(session, at, identifier: nil, conflict: false)
          session.pin_kb_document!(elemont)

          events = capture_case_logs do
            stub_ownership(analysis) do
              session.record_user_turn!(AMBIGUOUS, user_id: users(:one).id, correlation_id: "query:ambiguous")
            end
          end

          session.reload
          assert_equal :corrected, last_decision(events)
          assert_equal "ep_elemont", session.active_episode["episode_id"]
          assert_nil session.active_episode.dig("facts", "manufacturer")
          assert_nil session.active_episode.dig("facts", "manufacturer", "value")
          assert session.find_entity_by_kb_document_id(elemont.id)
          assert_includes SessionContextBuilder.entity_s3_uris(session), elemont.display_s3_uri(KbDocument::KB_BUCKET)
          refute_mismatch_release(events)
        end
      end
    end
  end

  test "a MiniSpace correction does not replace the manufacturer or release its pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-minispace.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    analysis = correction_analysis([ "MiniSpace", "equipment" ])

    travel_to(at) do
      with_episode_flags do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "conditional") do
          seed_case(session, at, identifier: nil, conflict: false, model: nil)
          session.pin_kb_document!(elemont)

          events = capture_case_logs do
            stub_ownership(analysis) do
              session.record_user_turn!(MODEL_CORRECTION, user_id: users(:one).id, correlation_id: "query:mini")
            end
          end

          session.reload
          assert_equal "ep_elemont", session.active_episode["episode_id"]
          assert_not_equal :new_episode, last_decision(events)
          assert_nil session.active_episode.dig("facts", "manufacturer", "value")
          assert_not_equal "MiniSpace", session.active_episode.dig("facts", "manufacturer", "value")
          assert session.find_entity_by_kb_document_id(elemont.id)
          assert_includes SessionContextBuilder.entity_s3_uris(session), elemont.display_s3_uri(KbDocument::KB_BUCKET)
          refute_mismatch_release(events)
        end
      end
    end
  end

  test "K1 does not correct the manufacturer or release the pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-k1.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    analysis = correction_analysis([ "K1", "equipment" ])

    travel_to(at) do
      with_episode_flags do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "conditional") do
          seed_case(session, at, identifier: nil, conflict: false, model: nil)
          session.pin_kb_document!(elemont)

          events = capture_case_logs do
            stub_ownership(analysis) do
              session.record_user_turn!("K1", user_id: users(:one).id, correlation_id: "query:k1")
            end
          end

          session.reload
          decision = last_decision(events)
          assert_not_equal :corrected, decision
          assert_not_equal :new_episode, decision
          assert_equal "ep_elemont", session.active_episode["episode_id"]
          assert_equal "Elemont", session.active_episode.dig("facts", "manufacturer", "value")
          assert session.find_entity_by_kb_document_id(elemont.id)
          assert_includes SessionContextBuilder.entity_s3_uris(session), elemont.display_s3_uri(KbDocument::KB_BUCKET)
          refute_mismatch_release(events)
          slice = events.find { |event| event["event"] == "haiku_ownership_slice" }
          assert_equal "correct", slice["relation"]
          assert_equal false, slice["ownership_applied"]
        end
      end
    end
  end

  test "a conditional correction keeps the Elemont pin, the neutral pin, and the KONE pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    session = web_session
    elemont = manual("elemont-multi.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    neutral = manual("neutral-multi.pdf", "Procedimiento de engrase")
    kone = manual("kone-multi.pdf", "KONE MonoSpace Special")
    analysis = correction_analysis([ "Elemont", "equipment" ], [ "KONE", "equipment" ])

    travel_to(at) do
      with_episode_flags do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "conditional") do
          seed_case(session, at, identifier: nil, conflict: false, model: nil, goal: nil)
          session.pin_kb_document!(elemont)
          session.pin_kb_document!(neutral)
          session.pin_kb_document!(kone)

          events = capture_case_logs do
            stub_ownership(analysis) do
              session.record_user_turn!(CORRECTION, user_id: users(:one).id, correlation_id: "query:multi")
            end
          end

          session.reload
          assert_equal :corrected, last_decision(events)
          assert_equal "ep_elemont", session.active_episode["episode_id"]
          assert_equal "KONE", session.active_episode.dig("facts", "manufacturer", "value")
          assert session.find_entity_by_kb_document_id(elemont.id)
          assert session.find_entity_by_kb_document_id(neutral.id)
          assert session.find_entity_by_kb_document_id(kone.id)
          assert_equal 3, session.document_focus_entries.size
          uris = SessionContextBuilder.entity_s3_uris(session)
          assert_includes uris, elemont.display_s3_uri(KbDocument::KB_BUCKET)
          assert_includes uris, neutral.display_s3_uri(KbDocument::KB_BUCKET)
          assert_includes uris, kone.display_s3_uri(KbDocument::KB_BUCKET)
          refute_mismatch_release(events)
        end
      end
    end
  end

  test "a single-brand conditional correction writes KONE and keeps the Elemont pin" do
    at = Time.zone.parse("2026-09-30 10:00:00")
    analysis = correction_analysis([ "KONE", "equipment" ])

    travel_to(at) do
      with_episode_flags do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "conditional") do
          conditional = correct_single_brand("conditional-single", at) do |episode_session|
            stub_ownership(analysis) do
              episode_session.record_user_turn!(SINGLE_BRAND, user_id: users(:one).id, correlation_id: "query:single")
            end
          end
          assert_equal "KONE", conditional.active_episode.dig("facts", "manufacturer", "value")
        end

        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") do
          deterministic = nil
          forbid_ownership do
            deterministic = correct_single_brand("off-single", at) do |episode_session|
              episode_session.record_user_turn!(SINGLE_BRAND, user_id: users(:one).id, correlation_id: "query:single-off")
            end
          end
          assert_equal "KONE", deterministic.active_episode.dig("facts", "manufacturer", "value")
          assert_equal "ep_elemont", deterministic.active_episode["episode_id"]
        end
      end
    end
  end

  private

  def correct_single_brand(key, at)
    session = web_session
    elemont = manual("#{key}.pdf", "Elemont Montacargas Hidraulico Modelo MH")
    seed_case(session, at, identifier: nil, conflict: false, model: "MH", goal: GOAL)
    session.pin_kb_document!(elemont)
    events = capture_case_logs do
      yield session
    end
    session.reload
    result_decision = last_decision(events)
    assert_equal :corrected, result_decision
    assert_equal "ep_elemont", session.active_episode["episode_id"]
    assert_equal "user", session.active_episode.dig("facts", "manufacturer", "source")
    assert_nil session.active_episode.dig("facts", "model")
    assert session.find_entity_by_kb_document_id(elemont.id)
    assert_includes SessionContextBuilder.entity_s3_uris(session), elemont.display_s3_uri(KbDocument::KB_BUCKET)
    refute_mismatch_release(events)
    session
  end

  def assert_kone_correction(session, session_result:)
    assert_equal :corrected, last_decision(session_result)
    assert_equal "ep_elemont", session.active_episode["episode_id"]
  end

  def refute_mismatch_release(events)
    assert events.none? { |event| event["event"] == "R1B_CASE_PROBE" }
    assert events.none? { |event| event["pin_release_reason"] == "corrected_manufacturer_mismatch" }
  end

  def last_decision(events)
    turn = events.reverse.find { |event| event["event"] == "field_companion_turn" }
    turn["episode_decision"].to_sym
  end

  def correction_analysis(*pairs)
    Rag::ConversationalTurnAnalysis.new(
      relation: "correct",
      mentions: pairs.map { |span, role| { "span" => span, "role" => role } },
      refers_to: [],
      ambiguous: false
    )
  end

  def web_session
    ConversationSession.create!(
      identifier: "web:conditional:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: users(:one),
      account: accounts(:legacy)
    )
  end

  def manual(key, name)
    KbDocument.create!(
      s3_key: "uploads/2026/conditional/#{key}",
      display_name: name,
      aliases: [],
      account: accounts(:legacy)
    )
  end

  def seed_case(session, at, identifier: "CEA15", conflict: true, model: "MH", goal: GOAL)
    facts = {
      "manufacturer" => {
        "status" => "known", "value" => "Elemont", "source" => "user",
        "correlation_id" => "seed", "at" => at.iso8601
      }
    }
    if model
      facts["model"] = {
        "status" => "known", "value" => model, "source" => "user",
        "correlation_id" => "seed", "at" => at.iso8601
      }
    end
    episode = {
      "v" => 1,
      "episode_id" => "ep_elemont",
      "status" => "active",
      "opened_at" => at.iso8601,
      "updated_at" => at.iso8601,
      "facts" => facts,
      "identifiers" => [],
      "conflicts" => []
    }
    episode["goal"] = { "text" => goal, "correlation_id" => "seed", "truncated" => false } if goal
    if identifier
      episode["identifiers"] = [
        { "value" => identifier, "source" => "user", "correlation_id" => "seed" }
      ]
    end
    if conflict
      episode["conflicts"] = [
        { "fact" => "manufacturer", "user" => "Elemont", "photo" => "KONE", "correlation_id" => "seed" }
      ]
    end
    session.update!(active_episode: episode)
  end

  def with_episode_flags
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") { yield }
    end
  end

  def stub_ownership(analysis)
    original = Rag::SemanticQueryAnalyzer.method(:observe_ownership)
    calls = []
    Rag::SemanticQueryAnalyzer.define_singleton_method(:observe_ownership) do |turn:, episode:, correlation_id:, client: nil, attribution: nil|
      calls << turn
      analysis
    end
    yield
    calls
  ensure
    restore_ownership(original)
  end

  def forbid_ownership
    original = Rag::SemanticQueryAnalyzer.method(:observe_ownership)
    Rag::SemanticQueryAnalyzer.define_singleton_method(:observe_ownership) do |*|
      raise "observe_ownership must not run while HAIKU_QUERY_ANALYSIS_MODE=off"
    end
    yield
  ensure
    restore_ownership(original)
  end

  def restore_ownership(original)
    return unless original

    Rag::SemanticQueryAnalyzer.define_singleton_method(:observe_ownership) do |*args, **kwargs|
      original.call(*args, **kwargs)
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
