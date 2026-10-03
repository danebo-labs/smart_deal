# frozen_string_literal: true

require "test_helper"

class Rag::WorkContextGoalTest < ActiveSupport::TestCase
  OPENING = "Ahora estoy revisando otro ascensor. No nivela en planta 3. Todavía no sé fabricante ni modelo."
  SYMPTOM = "No nivela en planta 3"
  FOLLOW = "queda un poco pasada de nivel"
  FRAMING = [
    "otro ascensor",
    "Todavía no sé fabricante ni modelo"
  ].freeze

  setup do
    @now = Time.current
    @user = users(:one)
    @account = accounts(:legacy)
  end

  test "new work stores the symptom and a later photo follow-up does not replay the opening" do
    session = web_session
    seed_previous_case(session)

    with_owner do
      opened = ask(session, OPENING, client(perception("new_work", observations: [ SYMPTOM ])), correlation: "query:new")
      session.reload
      episode = session.active_episode

      assert_equal :new_episode, opened.decision
      assert_not_equal "ep_old", episode["episode_id"]
      assert_equal SYMPTOM, episode.dig("goal", "text")
      assert_equal "query:new", episode.dig("goal", "correlation_id")
      assert_equal false, episode.dig("goal", "truncated")
      assert_nil episode.dig("facts", "manufacturer")
      assert_nil episode["active_photo"]
      assert_not_includes episode.to_json, "KONE"
      assert_not_includes episode.to_json, "la puerta no cierra"
      FRAMING.each { |phrase| assert_not_includes episode.dig("goal", "text"), phrase }

      blocked = session.record_photo_observation!(
        photo_value: { manufacturer: "Orona", model_visible: "PBCM-V3", relevance_to_goal: "uncertain" },
        field_photo_id: 41, sha256: "plate", correlation_id: "photo:plate",
        expected_episode_id: session.live_episode_id
      )
      session.reload
      assert_equal :applied, blocked
      assert_equal 41, session.active_episode.dig("active_photo", "field_photo_id")
      assert_nil session.active_episode.dig("facts", "manufacturer")
      assert_nil session.active_episode.dig("facts", "model")
      assert_equal SYMPTOM, session.active_episode.dig("goal", "text")

      session.record_photo_assistant_context!(
        "Placa leída",
        user_id: @user.id,
        correlation_id: "photo:reuse",
        expected_episode_id: session.live_episode_id,
        question: "si eso es el fabricante y placa, la consulta anterior",
        accepted_observation: {
          "manufacturer" => "Orona",
          "model" => "PBCM-V3",
          "relevance_to_goal" => "uncertain"
        },
        confirm_identity: true
      )
      session.reload
      assert_equal "Orona", session.active_episode.dig("facts", "manufacturer", "value")
      assert_equal "photo", session.active_episode.dig("facts", "manufacturer", "source")
      assert_equal "PBCM-V3", session.active_episode.dig("facts", "model", "value")
      assert_equal "photo", session.active_episode.dig("facts", "model", "source")
      assert_equal SYMPTOM, session.active_episode.dig("goal", "text")

      followed = ask(session, FOLLOW, client(perception("follow_up", observations: [ FOLLOW ])), correlation: "query:follow")
      session.reload
      query = followed.composed.to_s

      assert_equal :continued, followed.decision
      assert_equal SYMPTOM, session.active_episode.dig("goal", "text")
      assert_equal "Orona", session.active_episode.dig("facts", "manufacturer", "value")
      assert_equal "PBCM-V3", session.active_episode.dig("facts", "model", "value")
      assert_includes query, "Orona"
      assert_includes query, "PBCM-V3"
      assert_includes query, SYMPTOM
      assert_includes query, FOLLOW
      FRAMING.each { |phrase| assert_not_includes query, phrase }

      problem = SessionContextBuilder.field_problem_block(session)
      goal_line = problem.lines.find { |line| line.start_with?("Goal:") }.to_s
      assert_includes goal_line, SYMPTOM
      FRAMING.each { |phrase| assert_not_includes goal_line, phrase }
    end
  end

  test "a report that states the job keeps the symptom instead of the opening sentence" do
    turn = "Estoy revisando un ascensor. No nivela en planta 3. Todavía no sé fabricante ni modelo."
    episode, decision = settle(Rag::ActiveEpisode.new, perception("report", observations: [ SYMPTOM ]), turn)

    assert_equal "ready", decision.decision
    assert_equal SYMPTOM, episode.goal["text"]
    FRAMING.each { |phrase| assert_not_includes episode.goal["text"], phrase }
  end

  test "a turn with no symptom keeps the raw text as the goal" do
    turn = "El controlador es ABC900"
    episode, = settle(Rag::ActiveEpisode.new, perception("report", assertions: [ assertion("ABC900", "assert", "controller") ]), turn)

    assert_equal turn, episode.goal["text"]
    assert_includes episode.identifiers.pluck("value"), "ABC900"
  end

  test "a fault code without a symptom phrase stays in the goal" do
    turn = "E51 en NICE3000"
    raw = perception(
      "report",
      assertions: [ assertion("E51", "assert", "fault_code"), assertion("NICE3000", "assert", "controller") ],
      observations: [ "E51" ]
    )
    episode, = settle(Rag::ActiveEpisode.new, raw, turn)

    assert_empty episode.observations
    assert_equal turn, episode.goal["text"]
    assert_includes episode.identifiers.pluck("value"), "NICE3000"
  end

  test "several symptoms become one goal in interpreter order and stay inside the cap" do
    door = "no abre la puerta"
    shake = "además vibra"
    turn = "El ascensor no abre la puerta y además vibra"
    episode, = settle(Rag::ActiveEpisode.new, perception("report", observations: [ door, shake, door ]), turn)

    assert_equal "#{door} #{shake}", episode.goal["text"]
    assert_equal [ door, shake ], episode.observations.pluck("text")
  end

  test "a goal keeps whole symptoms and drops the tail that would exceed the cap" do
    turn = ("la puerta no abre y la cabina vibra " * 20)[0, 300].rstrip
    first = turn[0, 180].rstrip
    second = turn[-180, 180].lstrip
    assert_not_equal first, second
    assert_includes turn, first
    assert_includes turn, second
    assert_operator first.length + 1 + second.length, :>, Rag::ActiveEpisode::MAX_GOAL_CHARS

    episode, = settle(Rag::ActiveEpisode.new, perception("new_work", observations: [ first, second ]), turn)

    assert_equal first, episode.goal["text"]
    assert_not_includes episode.goal["text"], second
    assert_equal false, episode.goal["truncated"]
    assert_operator episode.goal["text"].length, :<=, Rag::ActiveEpisode::MAX_GOAL_CHARS
    assert_equal [ first, second ], episode.observations.pluck("text")
  end

  test "a follow-up does not replace a goal that is already set" do
    episode = open_episode
    episode.assign_goal!(SYMPTOM, correlation_id: "query:new")
    settled, = settle(episode, perception("follow_up", observations: [ FOLLOW ]), FOLLOW)

    assert_same episode, settled
    assert_equal SYMPTOM, settled.goal["text"]
    assert_equal "query:new", settled.goal["correlation_id"]
    assert_equal [ FOLLOW ], settled.observations.pluck("text")
  end

  test "an empty follow-up does not promote an older observation into the goal" do
    episode = open_episode
    episode.append_observation!("ruido viejo en la máquina", correlation_id: "old")
    turn = "¿Qué reviso?"
    settled, = settle(episode, perception("follow_up"), turn)

    assert_equal turn, settled.goal["text"]
  end

  test "a technical question without a symptom stays the goal" do
    episode = open_episode
    episode.write_fact!(
      "controller", status: "known", value: "NICE3000", source: "user",
      correlation_id: "seed", at: @now.iso8601
    )
    turn = "¿Cómo se ajustan los resortes?"
    settled, = settle(episode, perception("follow_up"), turn)

    assert_equal turn, settled.goal["text"]
  end

  test "a photo offer does not become the goal" do
    episode = open_episode
    episode.assign_goal!(SYMPTOM, correlation_id: "query:new")
    turn = "tengo una foto, te sirve?"
    settled, decision = settle(episode, perception("meta"), turn)

    assert_equal "meta", decision.decision
    assert_nil decision.retrieval_query
    assert_equal SYMPTOM, settled.goal["text"]
    assert_empty settled.observations
  end

  test "thin new work opens an empty episode and does not store the relational sentence" do
    previous = open_episode
    previous.assign_goal!("la puerta no cierra", correlation_id: "old")
    previous.pending_question = { "type" => "work_relation" }
    working, decision = settle(previous, perception("new_work"), "Es otro ascensor")

    assert_equal "clarify_first", decision.decision
    assert_equal "new_work", decision.dialogue_function
    assert_nil working.goal
    assert_empty working.observations
    assert_not_equal previous.episode_id, working.episode_id
    assert_equal "la puerta no cierra", previous.goal["text"]
  end

  test "interpreter fallback does not replace the stored goal" do
    session = web_session
    episode = open_episode
    episode.assign_goal!(SYMPTOM, correlation_id: "query:new")
    session.update!(active_episode: episode.to_h)

    result = with_owner do
      ask(session, OPENING, RaisingInterpreter.new, correlation: "query:fallback")
    end

    assert_equal :continued, result.decision
    assert_equal "timeout", result.reason
    assert_equal SYMPTOM, session.reload.active_episode.dig("goal", "text")
  end

  private

  def settle(previous, raw, turn)
    perception = Rag::TurnPerception.build(
      raw, turn: turn, episode: previous, catalog: nil, viewer_account: nil
    )
    policy_previous = perception.move == "new_work" ? Rag::ActiveEpisode.new : previous
    decision = Rag::RoutePolicy.call(
      previous: policy_previous, perception: perception, focus_count: 0, locale: :es
    )
    working = if perception.move == "new_work" || previous.blank?
      Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
    else
      previous
    end
    Rag::WorkContextReducer.apply!(
      episode: working, perception: perception, decision: decision,
      turn: turn, correlation_id: "seed", now: @now
    )
    [ working, decision ]
  end

  def open_episode
    Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
  end

  def with_owner(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
      end
    end
  end

  def ask(session, text, interpreter, correlation:)
    session.record_user_turn!(
      text,
      user_id: @user.id,
      correlation_id: correlation,
      interpreter_client: interpreter,
      now: @now
    )
  end

  def web_session
    ConversationSession.create!(
      identifier: "web:goal:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: @user,
      account: @account
    )
  end

  def seed_previous_case(session)
    session.update!(active_episode: {
      "v" => 1,
      "episode_id" => "ep_old",
      "status" => "active",
      "opened_at" => @now.iso8601,
      "updated_at" => @now.iso8601,
      "goal" => { "text" => "la puerta no cierra", "correlation_id" => "old", "truncated" => false },
      "facts" => {
        "manufacturer" => {
          "status" => "known", "value" => "KONE", "source" => "user",
          "correlation_id" => "old", "at" => @now.iso8601
        }
      },
      "observations" => [ { "text" => "la puerta no cierra", "correlation_id" => "old" } ],
      "active_photo" => { "field_photo_id" => 7, "sha256" => "old", "correlation_id" => "old" },
      "identifiers" => [],
      "conflicts" => [],
      "rejected" => []
    })
  end

  def perception(move, assertions: [], observations: [], pending_resolution: nil, clarification_target: nil)
    {
      "move" => move,
      "assertions" => assertions,
      "observations" => observations,
      "pending_resolution" => pending_resolution,
      "clarification_target" => clarification_target
    }
  end

  def assertion(span, act, hint = nil)
    item = { "span" => span, "act" => act }
    item["slot_hint"] = hint if hint
    item
  end

  def client(response)
    ScriptedInterpreter.new(response)
  end

  class ScriptedInterpreter
    def initialize(response)
      @response = response
    end

    def converse(_params)
      tool = Struct.new(:name, :input).new("turn_perception", @response)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(4, 2)
      Struct.new(:output, :usage).new(output, usage)
    end
  end

  class RaisingInterpreter
    def converse(*)
      raise Timeout::Error
    end
  end
end
