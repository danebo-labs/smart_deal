# frozen_string_literal: true

require "test_helper"

class Rag::MetaIncompatibleTurnTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  PHASE1 = "Estoy revisando un Elemont MH por un problema de puerta en el nivel 2. Según el plano seleccionado, ¿dónde aparece la seguridad de esa puerta y cómo se relaciona con las demás seguridades?"
  WITHOUT_MARK = "En el plano seleccionado ubica la seguridad de la puerta del nivel 2 y su relacion con las demas seguridades"
  MANUAL_QUERY = "En el manual ubica el contacto de la linea de seguridad del nivel 2"
  FIELD_QUERY = "el variador no arranca en el nivel 2"
  MIXED = "Puedo enviarte una foto, pero la puerta no cierra; ¿dónde aparece su seguridad en el plano?"
  META = {
    "move" => "meta",
    "assertions" => [],
    "observations" => [],
    "pending_resolution" => nil,
    "clarification_target" => nil
  }.freeze

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    Rag::Phase1PinnedTurn
    Rag::Phase1ModelBudget.disarm!
  end

  teardown do
    Rag::Phase1ModelBudget.disarm!
  end

  test "the guard is not the pinned phrase, a question mark, a brand, or the document pin" do
    source = Rails.root.join("app/services/rag/turn_perception.rb").read

    assert_not_includes source, "Elemont"
    assert_not_includes source, "seguridad de esa puerta"
    assert_not_includes source, 'include?("?")'
    assert_not_includes source, "document_focus"
    assert_not_includes source, "EQUIPMENT_SYMPTOM_RE"
    assert_not_includes source, "def greeting_turn?"
    assert_not_includes source, "def assistant_need_turn?"
    assert_equal Rag::TurnPerception::PROMPT_VERSION, "2026-10-07.2"
    assert_not_includes Rag::TurnInterpreter::PROMPT, "meta_incompatible"
  end

  test "a wrong meta on the pinned question keeps the query and the document route" do
    session, result, events, client, document = run_turn(PHASE1, pin: true)

    assert_equal 1, client.calls
    assert_equal 0, Rag::Phase1ModelBudget.attempts
    assert_not Rag::Phase1ModelBudget.armed?
    applied = events.find { |event| event["kind"] == "perception_applied" }
    raw = events.find { |event| event["kind"] == "interpreter_raw" }
    route = events.find { |event| event["kind"] == "route_decision" }
    query = events.find { |event| event["kind"] == "effective_query" }
    exit_event = events.find { |event| event["kind"] == "route_exit" }
    adjustment = applied["adjustments"].find { |row| row["reason"] == "meta_incompatible" }

    assert_equal "meta", raw.dig("tool_input", "move")
    assert_equal [], raw.dig("tool_input", "assertions")
    assert_equal [], raw.dig("tool_input", "observations")
    assert_equal "invalid", applied["result"]
    assert_equal false, applied["valid"]
    assert_nil applied["move"]
    assert_equal "meta", applied["original_move"]
    assert_equal "meta_incompatible", applied["invalid_reason"]
    assert_equal "reject_meta", adjustment["rule"]
    assert_equal "meta", adjustment["datum"]
    assert_equal "meta", adjustment.dig("detail", "from")
    assert_equal "fallback", adjustment.dig("detail", "to")
    assert_equal [], applied["identities"]
    assert_equal "ready", route["route"]
    assert_equal "fallback_ready", route["condition"]
    assert_equal true, route["retrieval"]
    assert_equal true, route["fallback"]
    assert_equal [ document.display_s3_uri(KbDocument::KB_BUCKET) ], route["focus_uris"]
    assert_equal [ document.id ], route["focus_document_ids"]
    assert_equal PHASE1, query["sent_turn"]
    assert_includes query["effective"], "seguridad de esa puerta"
    assert_includes query["effective"], "demás seguridades"
    assert_equal true, query["retrieval"]
    assert_equal "fallback", exit_event["exit"]
    assert_equal "meta_incompatible", exit_event["condition"]
    assert_equal "ready", result.understanding.decision
    assert result.understanding.performs_retrieval?
    assert result.understanding.fallback
    assert_nil result.understanding.clarification
    assert_equal [ document.id ], result.understanding.focus_document_ids
    assert_equal document.id, session.document_focus_entries.sole["kb_document_id"]
    assert_no_identity(session, PHASE1)
    assert events.none? { |event| %w[retrieve generate_text retrieve_and_generate model_call].include?(event["kind"]) }
  end

  test "the same question is kept with and without a pin, on the first turn and on a follow-up" do
    [
      { pin: false, goal: nil },
      { pin: true, goal: nil },
      { pin: false, goal: "ajustar frenos" },
      { pin: true, goal: "ajustar frenos" }
    ].each do |row|
      _session, result, events, client, document = run_turn(PHASE1, pin: row[:pin], goal: row[:goal])
      route = events.find { |event| event["kind"] == "route_decision" }
      query = events.find { |event| event["kind"] == "effective_query" }

      assert_equal 1, client.calls, row.inspect
      assert_equal "meta_incompatible", events.find { |event| event["kind"] == "perception_applied" }["invalid_reason"], row.inspect
      assert_equal "ready", route["route"], row.inspect
      assert_equal "fallback_ready", route["condition"], row.inspect
      assert_equal true, route["retrieval"], row.inspect
      assert_includes query["effective"], "seguridad de esa puerta", row.inspect
      assert_equal PHASE1, query["sent_turn"], row.inspect
      if row[:pin]
        assert_equal [ document.id ], result.understanding.focus_document_ids, row.inspect
      else
        assert_equal [], result.understanding.focus_uris, row.inspect
        assert_equal [], result.understanding.focus_document_ids, row.inspect
      end
      if row[:goal]
        assert_equal row[:goal], result.state.dig("goal", "text"), row.inspect
      end
      assert events.none? { |event| event["kind"] == "retrieve" }, row.inspect
    end
  end

  test "technical questions without a question mark and a direct manual query stay on the document route" do
    {
      WITHOUT_MARK => "seguridad de la puerta",
      MANUAL_QUERY => "linea de seguridad",
      FIELD_QUERY => "variador no arranca"
    }.each do |turn, fragment|
      assert_not_includes turn, "?"
      session, result, events, _client, _document = run_turn(turn, pin: false)
      query = events.find { |event| event["kind"] == "effective_query" }
      route = events.find { |event| event["kind"] == "route_decision" }

      assert_equal "meta_incompatible", events.find { |event| event["kind"] == "perception_applied" }["invalid_reason"], turn
      assert_equal "fallback_ready", route["condition"], turn
      assert_equal true, route["retrieval"], turn
      assert_includes query["effective"], fragment, turn
      assert_equal [], result.understanding.focus_uris, turn
      assert_no_identity(session, turn)
    end
  end

  test "a mixed evidence offer keeps the technical question and a lone offer stays meta" do
    session, result, events, _client, document = run_turn(MIXED, pin: true)
    query = events.find { |event| event["kind"] == "effective_query" }

    assert_equal "meta_incompatible", events.find { |event| event["kind"] == "perception_applied" }["invalid_reason"]
    assert_includes query["effective"], "puerta no cierra"
    assert_includes query["effective"], "foto"
    assert_equal true, events.find { |event| event["kind"] == "route_decision" }["retrieval"]
    assert_equal [ document.id ], result.understanding.focus_document_ids
    assert_no_identity(session, MIXED)

    [
      "hola",
      "Buenos días",
      "Hola, ¿qué tal?",
      "¿Qué necesitas que te mande?",
      "¿Qué necesitas de mí?",
      "Puedo enviarte una foto",
      "¿Cómo uso Danebo?",
      "¿Qué es Danebo?",
      "¿Cómo selecciono un manual?",
      "¿Qué manual elijo?"
    ].each do |turn|
      kept = perceive(turn)
      assert kept.valid, turn
      assert_equal "meta", kept.move, turn
      assert_nil kept.invalid_reason, turn
      assert_empty kept.identities, turn
    end

    pinned, pinned_result, pinned_events, _pinned_client, pinned_document = run_turn(
      "¿Cómo selecciono un manual?", pin: true, goal: "ajustar frenos"
    )
    assert_equal "meta", pinned_events.find { |event| event["kind"] == "perception_applied" }["move"]
    assert_nil pinned_events.find { |event| event["kind"] == "perception_applied" }["original_move"]
    assert_equal "meta", pinned_result.understanding.decision
    assert_not pinned_result.understanding.performs_retrieval?
    assert_equal "", pinned_events.find { |event| event["kind"] == "effective_query" }["effective"]
    assert_equal "ajustar frenos", pinned.active_episode.dig("goal", "text")
    assert_equal pinned_document.id, pinned.document_focus_entries.sole["kb_document_id"]
    assert pinned_events.none? { |event| event["kind"] == "retrieve" }
  end

  test "an open conversational question and the model budget stay in place" do
    assert_not Rag::Phase1ModelBudget.armed?
    session, result, events, client, document = run_turn(
      PHASE1,
      pin: true,
      goal: "ajustar frenos",
      pending: { "type" => "work_relation" }
    )
    route = events.find { |event| event["kind"] == "route_decision" }

    assert_equal 1, client.calls
    assert_equal 0, Rag::Phase1ModelBudget.attempts
    assert_equal "meta", events.find { |event| event["kind"] == "perception_applied" }["original_move"]
    assert_equal "meta_incompatible", events.find { |event| event["kind"] == "perception_applied" }["invalid_reason"]
    assert_equal "clarify_first", route["route"]
    assert_equal "fallback_conversational_pending", route["condition"]
    assert_equal false, route["retrieval"]
    assert_equal "", events.find { |event| event["kind"] == "effective_query" }["effective"]
    assert_equal "work_relation", result.state.dig("pending_question", "type")
    assert_equal [ document.id ], result.understanding.focus_document_ids
    assert_equal document.id, session.document_focus_entries.sole["kb_document_id"]
    assert_nil session.active_episode.dig("facts", "manufacturer")
    assert events.none? { |event| %w[retrieve generate_text retrieve_and_generate].include?(event["kind"]) }
  end

  private

  def run_turn(turn, pin:, goal: nil, pending: nil)
    session = web_session
    document = nil
    if pin
      document = KbDocument.create!(
        s3_key: "uploads/meta-guard/#{SecureRandom.hex(6)}.pdf",
        display_name: "Plano de prueba",
        document_uid: SecureRandom.uuid,
        aliases: [],
        account: @account
      )
      assert session.pin_kb_document!(document), turn
    end
    seed_episode(session, goal: goal, pending: pending) if goal || pending
    client = MetaStub.new
    result = nil
    events = []
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
        isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
          isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
            events = Rag::ValidationCapture.capture do
              result = session.record_user_turn!(
                turn,
                user_id: @user.id,
                correlation_id: "meta-guard:#{SecureRandom.hex(4)}",
                interpreter_client: client
              )
            end
          end
        end
      end
    end
    [ session.reload, result, events, client, document ]
  end

  def perceive(turn)
    Rag::TurnPerception.build(
      META, turn: turn, episode: Rag::ActiveEpisode.new, catalog: nil, viewer_account: nil
    )
  end

  def assert_no_identity(session, turn)
    episode = session.active_episode
    assert_nil episode.dig("facts", "manufacturer"), turn
    assert_nil episode.dig("facts", "model"), turn
    assert_nil episode.dig("facts", "controller"), turn
    assert_equal [], Array(episode["identifiers"]), turn
    Array(episode["observations"]).each do |item|
      assert turn.squish.start_with?(item["text"]), turn
    end
  end

  def web_session
    ConversationSession.create!(
      identifier: "web:meta-guard:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: @user,
      account: @account
    )
  end

  def seed_episode(session, goal:, pending:)
    payload = {
      "v" => 1,
      "episode_id" => "ep_seed",
      "status" => "active",
      "opened_at" => Time.current.iso8601,
      "updated_at" => Time.current.iso8601,
      "facts" => {},
      "identifiers" => [],
      "observations" => [],
      "conflicts" => []
    }
    payload["goal"] = { "text" => goal, "correlation_id" => "seed", "truncated" => false } if goal
    payload["pending_question"] = pending if pending
    session.update!(active_episode: payload)
  end

  class MetaStub
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def converse(_params)
      @calls += 1
      tool = Struct.new(:name, :input).new("turn_perception", META)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage).new(output, usage)
    end
  end
end
