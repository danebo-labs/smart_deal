# frozen_string_literal: true

require "test_helper"

# T3 of vf5-guion2-20261104T152432Z, session 267. The interpreter output and
# the planner question are the captured model output. This test does not
# call a model. It checks the product path that stores the sentence and the
# checker that reads it.
class Rag::CompanionDeclarationReplayTest < ActiveSupport::TestCase
  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/vf5_guion2_t3/turn.json").read)
  TURN = FIXTURE.fetch("turn")
  DECLARATION = "No he cambiado la configuración ni conectado o desconectado la fotocélula"
  CONDITION = FIXTURE.fetch("manual_condition")
  CAPTURED_QUESTION = FIXTURE.fetch("planner_question")

  test "the captured negation reaches the planner intact and is not asked again" do
    assert_empty FIXTURE.dig("interpreter", "observations")

    episode = apply_captured_turn
    excerpt = episode.excerpts.find { |row| row["text"] == DECLARATION }

    assert_equal DECLARATION, TURN[excerpt["a"]...excerpt["b"]]
    assert_not_includes excerpt["text"], "conexiones"
    assert_not_includes episode.observations.pluck("text"), DECLARATION

    prepared = Rag::CompanionPlan.prepare(
      raw_question: TURN,
      chunks: [ { content: "5.8 Pulsador de autoajuste (51)\n#{CONDITION}", metadata: { "page_number" => "8" } } ],
      episode: episode,
      session: Object.new
    )

    assert_includes prepared.user, "Mensaje de este turno:\n#{TURN}"
    assert_includes prepared.user, "Dicho por el técnico, sin indexar: «#{DECLARATION}»."
    assert_includes prepared.user, "configuración de los parámetros por defecto"
    assert_includes prepared.user, "conexión o desconexión de la fotocélula Fermator"

    checked = check_question(CAPTURED_QUESTION, episode, TURN)
    rendered = Rag::CompanionPlanRender.call(checked, facts: facts_for(episode), statements: statements)

    assert_equal "repeats_declaration", question_reason(checked)
    assert_nil checked.question
    assert_not_includes rendered, CAPTURED_QUESTION
    assert_not_includes rendered, "conexiones"
  end

  test "a question about conexiones widens the captured act and is dropped" do
    episode = apply_captured_turn
    checked = check_question("¿Cambió alguna conexión?", episode, TURN)

    assert_equal "widened_declaration:conex", question_reason(checked)
    assert_nil checked.question
  end

  test "a question that asks only the uncovered photocell condition stays" do
    turn = "No he cambiado la configuración."
    episode = apply_turn(turn)
    question = "¿Se realizó la conexión o desconexión de la fotocélula?"
    checked = check_question(question, episode, turn)

    assert_nil question_reason(checked)
    assert_equal question, checked.question
  end

  test "a question about the motor type the technician did not state stays" do
    episode = apply_captured_turn
    question = "¿El motor instalado es PM o asíncrono?"
    checked = Rag::CompanionPlanCheck.call(
      { "question" => question },
      facts: facts_for(episode),
      statements: motor_statements,
      turns: [ TURN ]
    )

    assert episode.excerpts.any? { |row| row["text"] == DECLARATION }
    assert_nil question_reason(checked)
    assert_equal question, checked.question
    rendered = Rag::CompanionPlanRender.call(checked, facts: facts_for(episode), statements: motor_statements)
    assert_includes rendered, question
    assert_not_includes rendered, "conexiones"
  end

  private

  def apply_captured_turn
    episode = Rag::ActiveEpisode.open(correlation_id: "query:t1", now: Time.current)
    episode.assign_goal!(
      "Después de un corte de alimentación, al volver la corriente la puerta abrió muy despacio",
      correlation_id: "query:t1"
    )
    apply_turn(TURN, episode, FIXTURE.fetch("interpreter"))
  end

  def apply_turn(turn, episode = nil, raw = nil)
    episode ||= Rag::ActiveEpisode.open(correlation_id: "query:t3", now: Time.current)
    perception = Rag::TurnPerception.build(
      raw || { "move" => "follow_up", "assertions" => [], "observations" => [], "checks" => [],
               "pending_resolution" => nil, "clarification_target" => nil, "part_replies" => [] },
      turn: turn, episode: episode, catalog: nil, viewer_account: nil
    )
    decision = Struct.new(:decision, :pending_question) do
      def performs_retrieval? = true
    end.new("retrieve", nil)
    Rag::WorkContextReducer.apply!(
      episode: episode, perception: perception, decision: decision,
      turn: turn, correlation_id: "query:t3", now: Time.current
    )
    episode
  end

  def check_question(question, episode, turn)
    Rag::CompanionPlanCheck.call(
      { "question" => question },
      facts: facts_for(episode),
      statements: statements,
      turns: [ turn ]
    )
  end

  def facts_for(episode)
    Rag::CompanionCaseFacts.build(episode, session: Object.new)
  end

  def statements
    @statements ||= Rag::CompanionStatements.parse([
      { content: "5.8 Pulsador de autoajuste (51)\n#{CONDITION}", metadata: { "page_number" => "8" } }
    ])
  end

  def motor_statements
    @motor_statements ||= Rag::CompanionStatements.parse([
      {
        content: [
          "5.8 Pulsador de autoajuste (51)",
          "Con un motor PM instalado el autoajuste ha de hacerse con la puerta de cabina acoplada y con la puerta de rellano.",
          "Con un motor asíncrono instalado el autoajuste ha de hacerse con la puerta de cabina acoplada pero sin la puerta de rellano.",
          CONDITION
        ].join("\n"),
        metadata: { "page_number" => "8" }
      }
    ])
  end

  def question_reason(result)
    result.rejections.find { |row| row["part"] == "question" }&.dig("reason")
  end
end
