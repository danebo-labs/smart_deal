# frozen_string_literal: true

require "test_helper"

class Rag::FieldCheckStateTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.parse("2026-10-21 15:00:00 UTC")
  end

  test "an observation does not create a check" do
    episode = open_episode
    turn = "no veo obstrucción en la puerta"

    with_owner { apply(episode, payload(observations: [ turn ]), turn) }

    assert_equal [ turn ], episode.observations.pluck("text")
    assert_empty episode.checks
  end

  test "not_done is stored and done with a result replaces the same subject" do
    episode = open_episode
    turn = "no he mirado la fotocélula"
    with_owner do
      apply(episode, payload(checks: [ check("la fotocélula", "not_done") ]), turn)
    end

    assert_equal [ { "subject" => "la fotocélula", "status" => "not_done", "correlation_id" => "turn" } ], episode.checks
    assert_empty episode.observations

    later = "ya revisé la fotocélula y nada"
    with_owner do
      apply(episode, payload(checks: [ check("la fotocélula", "done", "nada") ]), later)
    end

    stored = episode.checks.sole
    assert_equal "done", stored["status"]
    assert_equal "nada", stored["result"]
    assert_equal "la fotocélula", stored["subject"]
  end

  test "a correction replaces the stored check" do
    episode = open_episode
    with_owner do
      apply(episode, payload(checks: [ check("la fotocélula", "not_done") ]), "no he mirado la fotocélula")
    end
    turn = "Corrijo: ya revisé la fotocélula y no actúa"

    with_owner do
      apply(
        episode,
        payload(
          move: "correct",
          observations: [ "ya revisé la fotocélula y no actúa" ],
          checks: [ check("la fotocélula", "done", "no actúa") ]
        ),
        turn
      )
    end

    stored = episode.checks.sole
    assert_equal "done", stored["status"]
    assert_equal "no actúa", stored["result"]
  end

  test "new work opens an episode without the previous checks" do
    previous = open_episode
    previous.upsert_check!(check("la fotocélula", "not_done"), correlation_id: "old")
    turn = "otra falla: la puerta no abre"
    working = nil
    perception = nil

    with_owner do
      working, perception = apply(previous, payload(move: "new_work", observations: [ "la puerta no abre" ]), turn, fresh: true)
    end

    assert_equal "new_work", perception.move
    assert_empty working.checks
    assert_equal "la fotocélula", previous.checks.sole["subject"]
    assert_not_equal previous.episode_id, working.episode_id
  end

  test "checks are dropped after conflicts and before observations" do
    episode = open_episode
    episode.assign_goal!("g" * 280, correlation_id: "seed")
    12.times { |index| episode.append_observation!("obs#{index} #{'a' * 150}", correlation_id: "seed") }
    5.times { |index| episode.append_identifier!("CODE#{index}9", correlation_id: "seed", source: "user") }
    %w[manufacturer model controller].each do |fact|
      episode.add_conflict!(fact: fact, user: "u" * 40, photo: "p" * 40, correlation_id: "seed")
    end
    6.times do |index|
      episode.upsert_check!(
        check("sujeto #{index} #{'b' * 80}", "not_done", "r" * 80),
        correlation_id: "seed"
      )
    end

    payload = episode.to_h

    assert_equal [], payload["conflicts"]
    assert_operator Array(payload["checks"]).size, :<, 6
    assert_equal 12, payload["observations"].size
  end

  test "a payload without checks is valid and a bad check is not" do
    episode = open_episode
    turn = "la puerta se reabre sola"
    raw = payload
    perception = Rag::TurnPerception.build(raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil)

    assert perception.valid
    assert_equal [], perception.checks
    assert_equal true, Rag::InterpreterPayloadContract.evaluate(raw, sent_turn: turn)["valid"]
    assert_not_includes Rag::TurnPerception.tool_schema[:required], "checks"
    assert Rag::TurnPerception.tool_schema[:properties].key?(:checks)

    invented = payload(checks: [ check("fotocélula inventada", "not_done") ])
    refused = Rag::InterpreterPayloadContract.evaluate(invented, sent_turn: turn)
    assert_equal false, refused["valid"]
    assert_equal "span_not_literal", refused["reason"]

    bad_status = payload(checks: [ check("la puerta", "maybe") ])
    assert_equal "checks", Rag::InterpreterPayloadContract.evaluate(bad_status, sent_turn: turn)["reason"]

    too_long = payload(checks: [ check("la puerta #{'x' * 120}", "not_done") ])
    assert_equal "over_length", Rag::InterpreterPayloadContract.evaluate(too_long, sent_turn: "la puerta #{'x' * 120}")["reason"]
  end

  test "a fault prompt shows the check and omits plan blocks" do
    context = problem_for("la puerta se reabre sola", [ check("la fotocélula", "not_done") ])
    prompt = generation_prompt(context, [ { content: "La puerta se reabre sola. Verificar la fotocélula." } ])

    assert_includes context, "## Active Field Problem"
    assert_includes prompt, "Check: la fotocélula (not_done)"
    assert_not_includes prompt, "three logical sections"
    assert_not_includes prompt, "Según el plano"
    assert_not_includes prompt, "RECORD_TYPE: TOPOLOGY_EDGE"
    assert_not_includes prompt, "# LITERAL LABEL RULES"
    assert_includes prompt, "ACTION and EXPECTED_RESULT lines in FIELD_RECORD are extraction annotations"
  end

  test "plan blocks return for a topology record, a label table, or plano in the goal" do
    fault = problem_for("la puerta se reabre sola", [ check("la fotocélula", "not_done") ])
    topology = generation_prompt(fault, [ { content: "RECORD_TYPE: TOPOLOGY_EDGE\nACTION: A -> B" } ])
    table = generation_prompt(fault, [ { content: "Tabla de etiquetas\nBorne 9    Fotocélula" } ])
    drawing = problem_for("mirar el plano de la puerta", [ check("la fotocélula", "done", "nada") ])
    goal = generation_prompt(drawing, [ { content: "La puerta se reabre sola." } ])

    [ topology, table, goal ].each do |prompt|
      assert_includes prompt, "RECORD_TYPE: TOPOLOGY_EDGE record"
      assert_includes prompt, "Según el plano"
      assert_includes prompt, "# LITERAL LABEL RULES"
      assert_not_includes prompt, "three logical sections"
    end
    assert_includes goal, "Check: la fotocélula (done): nada"
  end

  private

  def open_episode
    Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
  end

  def check(subject, status, result = nil)
    { "subject" => subject, "status" => status, "result" => result }
  end

  def payload(move: "report", observations: [], assertions: [], checks: nil)
    raw = {
      "move" => move,
      "assertions" => assertions,
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
    raw["checks"] = checks unless checks.nil?
    raw
  end

  def apply(episode, raw, turn, fresh: false)
    perception = Rag::TurnPerception.build(raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil)
    working = fresh ? Rag::ActiveEpisode.open(correlation_id: "next", now: @now) : episode
    policy_previous = perception.move == "new_work" ? Rag::ActiveEpisode.new : episode
    decision = Rag::RoutePolicy.call(
      previous: policy_previous, perception: perception, focus_count: 0, locale: :es
    )
    Rag::WorkContextReducer.apply!(
      episode: working, perception: perception, decision: decision,
      turn: turn, correlation_id: "turn", now: @now
    )
    [ working, perception ]
  end

  def problem_for(goal, checks)
    episode = open_episode
    episode.assign_goal!(goal, correlation_id: "seed")
    checks.each { |item| episode.upsert_check!(item, correlation_id: "seed") }
    SessionContextBuilder.send(:render_field_problem, episode)
  end

  def generation_prompt(session_context, chunks)
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    service.send(
      :document_identity_generation_prompt,
      "la puerta se reabre sola",
      chunks,
      response_locale: :es,
      session_context: session_context,
      output_channel: :web
    ).to_s
  end

  def with_owner(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
      end
    end
  end
end
