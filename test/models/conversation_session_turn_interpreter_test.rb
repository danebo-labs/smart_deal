# frozen_string_literal: true

require "test_helper"

class ConversationSessionTurnInterpreterTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.parse("2026-10-02 12:00:00")
    @user = users(:one)
    @account = accounts(:legacy)
  end

  test "Q2 with no focus asks for the equipment and does not retrieve or store a fault" do
    session = web_session
    result = with_owner do
      ask(session, "¿Que es Q2?", client(mention("Q2")))
    end

    assert result.understanding.clarify_first?
    assert_nil result.composed
    assert_equal [ "Q2" ], session.reload.active_episode.dig("pending_question", "carry")
    assert_nil session.active_episode.dig("facts", "fault_code")
    assert_nil session.active_episode["goal"]
  end

  test "Q2 carry survives the identity answer and the query keeps both" do
    session = web_session
    doc = manual("nice.pdf")
    with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(monarch_catalog(doc)) do
        ask(session, "¿Qué es Q2?", client(mention("Q2")), correlation: "query:q2")
        result = ask(
          session, "Monarch NICE3000",
          client(
            perception(
              "answer_pending",
              assertions: [ assertion("Monarch", "assert"), assertion("NICE3000", "assert") ],
              pending_resolution: "value"
            )
          ),
          correlation: "query:nice"
        )
        assert_equal "ready", result.understanding.decision
        assert_includes result.composed, "Q2"
        assert_includes result.composed, "NICE3000"
        assert_match(/monarch/i, result.composed)
      end
    end

    facts = session.reload.active_episode["facts"]
    assert_equal "NICE3000", facts.dig("controller", "value")
    assert_equal "catalog", facts.dig("controller", "source")
    assert_equal "MONARCH", facts.dig("manufacturer", "value")
    assert_nil session.active_episode["pending_question"]
  end

  test "Q2 seek keeps the token and does not ask again" do
    session = web_session
    result = with_owner do
      ask(session, "¿Qué es Q2?", client(mention("Q2")), correlation: "query:q2")
      ask(
        session, "No sé, busca con eso",
        client(perception("answer_pending", pending_resolution: "seek")),
        correlation: "query:seek"
      )
    end

    assert result.understanding.best_effort?
    assert_includes result.composed, "Q2"
    assert_nil result.understanding.clarification
    assert_nil session.reload.active_episode["pending_question"]
  end

  test "a new job drops the Q2 carry" do
    session = web_session
    with_owner do
      ask(session, "¿Qué es Q2?", client(mention("Q2")), correlation: "query:q2")
      result = ask(
        session, "otra falla: puertas no cierran",
        client(perception("new_work", observations: [ "puertas no cierran" ])),
        correlation: "query:doors"
      )
      assert_equal "ready", result.understanding.decision
      assert_not_includes result.composed.to_s, "Q2"
      assert_includes result.composed, "puertas"
    end

    assert_nil session.reload.active_episode.dig("pending_question", "carry")
    identifiers = Array(session.active_episode["identifiers"]).pluck("value")
    assert_not_includes identifiers, "Q2"
  end

  test "VF5 with a door symptom searches the code and does not require a controller" do
    session = web_session
    text = "Es VF5, intenta cerrar, vuelve a abrir y marca E03."
    result = with_owner do
      ask(session, text, client(perception(
        "report",
        assertions: [ assertion("VF5", "assert"), assertion("E03", "assert", "fault_code") ],
        observations: [ "intenta cerrar, vuelve a abrir" ]
      )))
    end

    assert_equal "ready", result.understanding.decision
    assert_nil result.understanding.pending_question
    assert_includes result.composed, "VF5"
    assert_includes result.composed, "E03"
    assert_equal "E03", session.reload.active_episode.dig("facts", "fault_code", "value")
    assert_nil session.active_episode.dig("facts", "controller")
  end

  test "a follow-up keeps the open job" do
    session = web_session
    seed_episode(session, facts: { "controller" => known("NICE3000"), "fault_code" => known("E51") }, goal: "Nice300 e51")
    opened = session.live_episode_id
    result = with_owner do
      ask(session, "¿Qué reviso?", client(perception("follow_up")))
    end

    assert_equal "ready", result.understanding.decision
    assert_equal opened, session.reload.live_episode_id
    assert_equal "Nice300 e51", session.active_episode.dig("goal", "text")
    assert_includes result.composed, "NICE3000"
    assert_includes result.composed, "E51"
  end

  test "an unknown pending answer is confirmed and the reply is not the query" do
    session = web_session
    seed_episode(
      session,
      goal: "la puerta no abre",
      pending_question: { "type" => "controller" },
      pending_fact: { "subject" => "controller", "correlation_id" => "seed" }
    )
    result = with_owner do
      ask(session, "Volviendo a eso, no lo sé", client(perception("answer_pending", pending_resolution: "unknown")))
    end

    assert result.understanding.best_effort?
    assert_equal "unknown_confirmed", session.reload.active_episode.dig("facts", "controller", "status")
    assert_not_includes result.composed.to_s, "no lo sé"
    assert_includes result.composed, "la puerta no abre"
  end

  test "an uncatalogued pending answer takes the slot Danebo asked" do
    session = web_session
    seed_episode(
      session,
      pending_question: { "type" => "controller" },
      pending_fact: { "subject" => "controller", "correlation_id" => "seed" }
    )
    with_owner do
      ask(session, "ABC900", client(perception("answer_pending", assertions: [ assertion("ABC900", "assert", "model") ], pending_resolution: "value")))
    end

    fact = session.reload.active_episode.dig("facts", "controller")
    assert_equal "ABC900", fact["value"]
    assert_equal "user", fact["source"]
    assert_nil session.active_episode.dig("facts", "model")
  end

  test "an asserted literal is context and does not ask for a controller" do
    session = web_session
    result = with_owner do
      ask(session, "El controlador es ABC900", client(perception("report", assertions: [ assertion("ABC900", "assert", "controller") ])))
    end

    assert_equal "ready", result.understanding.decision
    assert_not result.understanding.clarify_first?
    identifiers = Array(session.reload.active_episode["identifiers"]).pluck("value")
    assert_includes identifiers, "ABC900"
  end

  test "a meta question does not become an observation or a query" do
    session = web_session
    result = with_owner do
      ask(session, "¿Necesitas controlador?", client(perception("meta")))
    end

    assert result.understanding.meta?
    assert_nil result.composed
    assert_nil session.reload.active_episode["goal"]
    assert_nil session.active_episode["observations"]
  end

  test "a correction replaces the active controller and rejects the old value" do
    session = web_session
    seed_episode(session, facts: { "controller" => known("NICE3000", source: "catalog") })
    text = "No, no es NICE3000. Es NICE1000."
    with_owner do
      ask(session, text, client(perception("correct", assertions: [
        assertion("NICE3000", "negate"),
        assertion("NICE1000", "assert")
      ])))
    end

    episode = session.reload.active_episode
    assert_equal "NICE1000", episode.dig("facts", "controller", "value")
    assert_equal "user", episode.dig("facts", "controller", "source")
    assert_includes episode["rejected"].pluck("value"), "NICE3000"
  end

  test "an uncatalogued replacement takes the corrected slot" do
    session = web_session
    seed_episode(session, facts: { "controller" => known("NICE3000") })
    text = "No, no es NICE3000. Es ABC900."
    with_owner do
      ask(session, text, client(perception("correct", assertions: [
        assertion("NICE3000", "negate"),
        assertion("ABC900", "assert")
      ])))
    end

    episode = session.reload.active_episode
    assert_equal "ABC900", episode.dig("facts", "controller", "value")
    assert_equal "user", episode.dig("facts", "controller", "source")
    assert_includes episode["rejected"].pluck("value"), "NICE3000"
  end

  test "new work opens another episode and clears the procedure" do
    session = web_session
    seed_episode(
      session,
      goal: "ajuste de frenos",
      observations: [ { "text" => "ruido en la máquina", "correlation_id" => "seed" } ],
      procedure: { "step" => 1 }
    )
    previous = session.live_episode_id
    logs = capture_logs do
      with_owner do
        ask(session, "otra falla: puertas no cierran", client(perception("new_work", observations: [ "puertas no cierran" ])))
      end
    end

    session.reload
    assert_not_equal previous, session.live_episode_id
    assert_equal({}, session.current_procedure)
    assert_not_includes session.active_episode.dig("goal", "text").to_s, "ajuste de frenos"
    texts = Array(session.active_episode["observations"]).pluck("text")
    assert_not_includes texts, "ruido en la máquina"
    assert_match(/"case_boundary_reason":"new_episode"/, logs)
  end

  test "a focus change after Haiku uses the fresh focus and does not fall back" do
    session = web_session
    uri = "s3://test-bucket/manuals/focus.pdf"
    doc = manual("focus.pdf")
    interpreter = FocusMutatingClient.new(session, mention("Q2"), uri, doc.id)
    result = with_owner { ask(session, "¿Que es Q2?", interpreter) }

    assert_equal "search_and_clarify", result.understanding.decision
    assert_not result.understanding.fallback
    assert_includes result.understanding.focus_uris, uri
    assert_includes result.composed, "Q2"
    assert_nil session.reload.active_episode.dig("facts", "fault_code")
  end

  test "a private catalog identity stays an unresolved identifier for the other tenant" do
    owner = accounts(:legacy)
    outsider = web_session(account: accounts(:climb))
    uid = SecureRandom.uuid
    key = "manuals/#{uid}.pdf"
    KbDocument.create!(account: owner, s3_key: key, display_name: "Private", document_uid: uid, aliases: [])
    catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [ catalog_entry(owner, uid, key, "SecretCo", "PRIVATE900", "controller") ]
    })

    with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(catalog) do
        ask(outsider, "PRIVATE900", client(perception("report", assertions: [ assertion("PRIVATE900", "assert", "controller") ])))
      end
    end

    episode = outsider.reload.active_episode
    assert_nil episode.dig("facts", "controller")
    assert_nil episode.dig("facts", "manufacturer")
    assert_not_includes episode.to_json, "SecretCo"
    assert_includes Array(episode["identifiers"]).pluck("value"), "PRIVATE900"
  end

  test "the caption is interpreted and a photo request does not reuse that query" do
    session = web_session
    doc = manual("nice.pdf")
    with_owner do
      Rag::DocumentIdentityCatalog.with_catalog(monarch_catalog(doc)) do
        ask(session, "el controlador es NICE3000", client(perception("report", assertions: [ assertion("NICE3000", "assert") ])))
      end
    end
    assert_equal "NICE3000", session.reload.active_episode.dig("facts", "controller", "value")

    concern = Class.new { include RagQueryConcern }.new
    episode_turn = Struct.new(:understanding).new(Object.new)
    assert_nil concern.send(:turn_understanding_for, "el controlador es NICE3000", session, episode_turn, nil, [ {} ], [], false)
  end

  test "the same correlation does not call Haiku twice or append a second bubble" do
    session = web_session
    interpreter = client(perception("report", assertions: [ assertion("ABC900", "assert") ]))
    with_owner do
      ask(session, "El controlador es ABC900", interpreter, correlation: "query:same")
      second = ask(session, "El controlador es ABC900", interpreter, correlation: "query:same")
      assert_equal "duplicate_correlation", second.reason
    end

    assert_equal 1, interpreter.payloads.size
    assert_equal 1, session.reload.conversation_history.count { |row| row["role"] == "user" }
  end

  test "an episode that changes before the lock is not rewritten from the model" do
    session = web_session
    interpreter = SnapshotMutatingClient.new(session, perception("report", assertions: [ assertion("ABC900", "assert") ]))
    result = with_owner { ask(session, "El controlador es ABC900", interpreter) }

    assert result.understanding.fallback
    assert_equal "otro trabajo", session.reload.active_episode.dig("goal", "text")
    assert_not_includes Array(session.active_episode["identifiers"]).pluck("value"), "ABC900"
  end

  test "Haiku sees the same truncated turn that is stored and validated" do
    session = web_session
    text = (("palabra " * 40) + "COLADETRAS")
    interpreter = client(perception("report", assertions: [ assertion("COLADETRAS", "assert") ]))
    with_owner { ask(session, text, interpreter) }

    stored = session.reload.conversation_history.last["content"]
    sent = JSON.parse(interpreter.payloads.first[:messages].first[:content].first[:text])
    assert_equal Rag::TurnText.truncate(text), stored
    assert_equal stored, sent["turn"]
    assert_not_includes stored, "COLADETRAS"
    assert_not_includes Array(session.active_episode["identifiers"]).pluck("value"), "COLADETRAS"
  end

  test "an expired episode is sent to Haiku without the old job" do
    session = web_session
    seed_episode(session, goal: "objetivo viejo", at: @now - 5.hours, procedure: { "step" => 3 })
    interpreter = client(perception("report", observations: [ "la puerta no cierra bien" ]))
    logs = capture_logs do
      with_owner { ask(session, "la puerta no cierra bien ahora", interpreter, now: @now) }
    end

    sent = JSON.parse(interpreter.payloads.first[:messages].first[:content].first[:text])
    assert_equal({}, sent["work_context"])
    session.reload
    assert_not_includes session.active_episode.dig("goal", "text").to_s, "objetivo viejo"
    assert_equal({}, session.current_procedure)
    assert_match(/"case_boundary_reason":"episode_expired"/, logs)
  end

  test "owner mode leaves a menu selection on the legacy recorder" do
    session = web_session
    interpreter = client(perception("report"))
    def interpreter.converse(*)
      raise "owner interpreter must not run for a selection"
    end

    assert_nothing_raised do
      with_owner do
        session.record_user_turn!(
          "Manual A", user_id: @user.id, correlation_id: "query:menu", selection_turn: true, interpreter_client: interpreter
        )
      end
    end
    assert_equal 1, session.reload.conversation_history.count { |row| row["role"] == "user" }
  end

  test "the default mode does not call the owner interpreter" do
    session = web_session
    interpreter = client(perception("report"))
    def interpreter.converse(*)
      raise "owner interpreter must stay off"
    end

    assert_nothing_raised do
      isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
        isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
          isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "off") do
            session.record_user_turn!(
              "la puerta no cierra", user_id: @user.id, correlation_id: "query:off", interpreter_client: interpreter
            )
          end
        end
      end
    end
  end

  private

  def with_owner(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
      end
    end
  end

  def ask(session, text, interpreter, correlation: nil, now: Time.current)
    session.record_user_turn!(
      text,
      user_id: @user.id,
      correlation_id: correlation || "query:#{SecureRandom.hex(4)}",
      interpreter_client: interpreter,
      now: now
    )
  end

  def web_session(account: @account)
    ConversationSession.create!(
      identifier: "web:owner:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: @user,
      account: account
    )
  end

  def manual(key)
    KbDocument.create!(
      s3_key: "uploads/2026/owner/#{key}",
      display_name: key,
      document_uid: SecureRandom.uuid,
      aliases: [],
      account: @account
    )
  end

  def monarch_catalog(doc)
    Rag::DocumentIdentityCatalog.new({
      "documents" => [ catalog_entry(@account, doc.document_uid, doc.s3_key, "MONARCH", "NICE3000", "controller") ]
    })
  end

  def catalog_entry(account, uid, key, brand, designator, type)
    {
      "account_id" => account.id.to_s,
      "document_id" => uid,
      "s3_key" => key,
      "display_name" => designator,
      "brands" => [ brand ],
      "designators" => [ { "value" => designator, "type" => type } ],
      "generic" => false,
      "confirmed" => true
    }
  end

  def seed_episode(session, facts: {}, goal: nil, observations: [], pending_question: nil, pending_fact: nil, procedure: {}, at: @now)
    payload = {
      "v" => 1,
      "episode_id" => "ep_seed",
      "status" => "active",
      "opened_at" => at.iso8601,
      "updated_at" => at.iso8601,
      "facts" => facts,
      "identifiers" => [],
      "observations" => observations,
      "conflicts" => []
    }
    payload["goal"] = { "text" => goal, "correlation_id" => "seed", "truncated" => false } if goal
    payload["pending_question"] = pending_question if pending_question
    payload["pending_fact"] = pending_fact if pending_fact
    session.update!(active_episode: payload, current_procedure: procedure)
  end

  def known(value, source: "user")
    { "status" => "known", "value" => value, "source" => source, "correlation_id" => "seed", "at" => @now.iso8601 }
  end

  def mention(span)
    perception("report", assertions: [ assertion(span, "mention") ])
  end

  def perception(move, assertions: [], observations: [], pending_resolution: nil)
    {
      "move" => move,
      "assertions" => assertions,
      "observations" => observations,
      "pending_resolution" => pending_resolution
    }
  end

  def assertion(span, act, hint = nil)
    item = { "span" => span, "act" => act }
    item["slot_hint"] = hint if hint
    item
  end

  def client(response)
    ScriptedInterpreterClient.new([ response ])
  end

  def capture_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  class ScriptedInterpreterClient
    attr_reader :payloads

    def initialize(responses)
      @responses = responses.dup
      @payloads = []
    end

    def converse(params)
      @payloads << params
      tool = Struct.new(:name, :input).new("turn_perception", @responses.shift)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(4, 2)
      Struct.new(:output, :usage).new(output, usage)
    end
  end

  class FocusMutatingClient < ScriptedInterpreterClient
    def initialize(session, response, uri, document_id)
      super([ response ])
      @session = session
      @uri = uri
      @document_id = document_id
    end

    def converse(params)
      @session.update!(document_focus: [ {
        "kb_document_id" => @document_id,
        "source_uri" => @uri,
        "display_name" => "Focus manual",
        "added_at" => Time.current.iso8601
      } ])
      super
    end
  end

  class SnapshotMutatingClient < ScriptedInterpreterClient
    def initialize(session, response)
      super([ response ])
      @session = session
    end

    def converse(params)
      @session.update!(active_episode: {
        "v" => 1,
        "episode_id" => "ep_other",
        "status" => "active",
        "opened_at" => Time.current.iso8601,
        "updated_at" => Time.current.iso8601,
        "goal" => { "text" => "otro trabajo", "correlation_id" => "x", "truncated" => false }
      })
      super
    end
  end
end
