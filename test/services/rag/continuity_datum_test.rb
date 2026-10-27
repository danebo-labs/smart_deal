# frozen_string_literal: true

require "test_helper"
require_relative "../../support/companion_plan_response"

# The datum, the null list, and a continuity request. The names are a pump,
# not the VF5, so the rule is not a manual or a terminal number.
class Rag::ContinuityDatumTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  VALVE = "¿La válvula 4 está abierta?"
  LIGHT = "¿El indicador encendido es el de marcha o el de fallo?"
  OTHER = "No sé cómo saber la presión del sensor 9 ni si el contacto 9-11 está cerrado."
  MANUAL = <<~TEXT
    • La válvula no abre.
    – Comprobar si la válvula 4 está abierta.
    • Marcha.
    El indicador de marcha está encendido cuando la marcha está activa.
    • Fallo.
    El indicador de fallo está encendido cuando hay un fallo.
    • La compuerta no abre.
    – Comprobar si la compuerta está abierta.
  TEXT

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
  end

  test "a continuity request is not stored when the tool is rejected" do
    with_flags do
      session = open_session
      session.record_user_turn!(
        "La válvula 4 está cerrada.",
        user_id: @user.id, correlation_id: "query:valve-report",
        interpreter_client: tool_client("report", [ "La válvula 4 está cerrada." ])
      )
      result = session.record_user_turn!(
        "¿Qué sigue?",
        user_id: @user.id, correlation_id: "query:what-next",
        interpreter_client: tool_client("follow_up", [], "documented_context")
      )
      episode = Rag::ActiveEpisode.parse(session.reload.active_episode)

      assert_equal "invalid_schema", result.reason
      assert_equal "La válvula 4 está cerrada.", episode.goal["text"]
      assert episode.observations.none? { |item| item["text"].match?(/qu[eé] sigue/i) }
    end
  end

  test "a rejected report that names the equipment is still kept" do
    with_flags do
      session = open_session
      session.record_user_turn!(
        "La bomba pierde presión.",
        user_id: @user.id, correlation_id: "query:leak",
        interpreter_client: tool_client("report", [ "La bomba pierde presión." ], "documented_context")
      )
      episode = Rag::ActiveEpisode.parse(session.reload.active_episode)

      assert episode.observations.any? { |item| item["text"] == "La bomba pierde presión." }
    end
  end

  test "another component does not answer the open datum and a bare unknown does" do
    with_flags do
      session = open_session
      session.record_user_turn!(
        "La bomba no arranca.",
        user_id: @user.id, correlation_id: "query:valve-open",
        interpreter_client: tool_client("report", [ "La bomba no arranca." ])
      )
      publish(session, VALVE, "La válvula no abre.")
      valve = Rag::ActiveEpisode.parse(session.reload.active_episode).pending_question
      assert_equal VALVE, valve["question"]

      publish(session, LIGHT, "Marcha.")
      held = Rag::ActiveEpisode.parse(session.reload.active_episode).pending_question
      assert_equal VALVE, held["question"]
      assert_equal LIGHT, held.dig("shown", "question")

      session.record_user_turn!(
        OTHER,
        user_id: @user.id, correlation_id: "query:sensor",
        interpreter_client: tool_client("meta", [])
      )
      after_other = Rag::ActiveEpisode.parse(session.reload.active_episode)
      unknown = after_other.observations.find { |item| item["text"] == OTHER }

      assert unknown
      assert_equal "unknown", unknown.dig("answers", "r")
      assert_nil unknown.dig("answers", "q")
      assert_equal VALVE, after_other.pending_question["question"]
      assert_equal LIGHT, after_other.pending_question.dig("shown", "question")

      composed = publish(session, "¿Está cerrada la válvula 4?", "La válvula no abre.", ask: false)
      assert_equal "referent_clarification", composed.check.question_role
      assert_includes composed.text, "válvula 4"
      assert_includes composed.text, "indicador encendido"
      assert_nil composed.pending

      bare = open_session
      bare.record_user_turn!(
        "La bomba no arranca.",
        user_id: @user.id, correlation_id: "query:valve-bare",
        interpreter_client: tool_client("report", [ "La bomba no arranca." ])
      )
      publish(bare, VALVE, "La válvula no abre.")
      bare.record_user_turn!(
        "No sé",
        user_id: @user.id, correlation_id: "query:bare",
        interpreter_client: tool_client("report", [])
      )
      answered = Rag::ActiveEpisode.parse(bare.reload.active_episode)
      limit = answered.observations.find { |item| item.dig("answers", "r") == "unknown" }

      assert_equal VALVE, limit.dig("answers", "q")
      assert_nil answered.pending_question
    end
  end

  test "a shared property does not make two unnamed components the same datum" do
    question = { "question" => "¿La válvula está abierta?", "targets" => [ { "item" => "Válvula." } ] }

    assert_not Rag::WorkContextReducer.same_published_datum?(question, "No sé si la compuerta está abierta")
    assert Rag::WorkContextReducer.same_published_datum?(question, "Está abierta")
    assert Rag::WorkContextReducer.same_published_datum?(question, "No sé")

    with_flags do
      session = open_session
      session.record_user_turn!(
        "La bomba no arranca.",
        user_id: @user.id, correlation_id: "query:pump",
        interpreter_client: tool_client("report", [ "La bomba no arranca." ])
      )
      publish(session, "¿La válvula está abierta?", "La válvula no abre.")
      session.record_user_turn!(
        "No sé si la compuerta está abierta",
        user_id: @user.id, correlation_id: "query:gate",
        interpreter_client: tool_client("report", [ "No sé si la compuerta está abierta" ])
      )
      kept = Rag::ActiveEpisode.parse(session.reload.active_episode)
      gate = kept.observations.find { |item| item["text"].include?("compuerta") }

      assert gate
      assert_nil gate.dig("answers", "q")
      assert_equal "¿La válvula está abierta?", kept.pending_question["question"]

      session.record_user_turn!(
        "Está abierta",
        user_id: @user.id, correlation_id: "query:open",
        interpreter_client: tool_client("report", [ "Está abierta" ])
      )
      answered = Rag::ActiveEpisode.parse(session.reload.active_episode)
      opening = answered.observations.find { |item| item["text"] == "Está abierta" }

      assert_equal "¿La válvula está abierta?", opening.dig("answers", "q")
      assert_nil answered.pending_question

      both = open_session
      both.record_user_turn!(
        "La bomba no arranca.",
        user_id: @user.id, correlation_id: "query:pump-both",
        interpreter_client: tool_client("report", [ "La bomba no arranca." ])
      )
      publish(both, "¿La válvula está abierta?", "La válvula no abre.")
      publish(both, "¿La compuerta está abierta?", "La compuerta no abre.")
      held = Rag::ActiveEpisode.parse(both.reload.active_episode)
      assert_equal "¿La válvula está abierta?", held.pending_question["question"]
      assert_equal "¿La compuerta está abierta?", held.pending_question.dig("shown", "question")

      both.record_user_turn!(
        "Está abierta",
        user_id: @user.id, correlation_id: "query:which",
        interpreter_client: tool_client("report", [ "Está abierta" ])
      )
      waiting = Rag::ActiveEpisode.parse(both.reload.active_episode)
      reply = waiting.observations.find { |item| item["text"] == "Está abierta" }

      assert_nil reply.dig("answers", "q")
      assert_equal "¿La válvula está abierta?", waiting.pending_question["question"]
      assert_equal "¿La compuerta está abierta?", waiting.pending_question.dig("shown", "question")

      composed = publish(both, "¿La válvula está abierta?", "La válvula no abre.", ask: false)
      assert_equal "referent_clarification", composed.check.question_role
      assert_includes composed.text, "válvula está abierta"
      assert_includes composed.text, "compuerta está abierta"
      assert_nil composed.pending
    end
  end

  test "the same number with another property is not the open datum" do
    question = { "question" => "¿La válvula 4 está abierta?", "targets" => [ { "item" => "Válvula." } ] }
    pressure = "No sé cómo saber la presión de la válvula 4."
    same = "No sé si la válvula 4 está abierta."

    assert_not Rag::WorkContextReducer.same_published_datum?(question, pressure)
    assert Rag::WorkContextReducer.same_published_datum?(question, same)
    assert Rag::WorkContextReducer.same_published_datum?(question, "No sé")
  end

  private

  def with_flags
    previous_mode = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    previous_episode = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      yield
    end
  ensure
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous_mode
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous_episode
  end

  def open_session
    ConversationSession.create!(
      identifier: "web:datum-#{SecureRandom.hex(3)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: @user,
      account: @account,
      active_episode: {},
      conversation_history: []
    )
  end

  def publish(session, question, item_text, ask: true)
    episode = Rag::ActiveEpisode.parse(session.reload.active_episode)
    chunks = [ {
      content: MANUAL,
      metadata: { "page_number" => "2", "original_source_uri" => "s3://fixture/pump.pdf", "filename" => "chunk_p2_1.txt" },
      identity_applicability: "compatible"
    } ]
    prepared = Rag::CompanionPlan.prepare(
      raw_question: question, chunks: chunks, episode: episode, session: session, correlation_id: "query:plan"
    )
    item = prepared.statements.statements.find { |row| row.kind == "item" && row.text.include?(item_text) }
    steps = prepared.statements.statements.select(&:step?).map(&:id)
    composed = Rag::CompanionPlan.compose(
      CompanionPlanResponse.build({
        "links" => [], "steps" => steps, "question" => question, "question_about" => [ item.id ]
      }),
      prepared
    )
    if ask
      assert_equal question, composed.check.question, composed.check.rejections.inspect
      session.record_assistant_turn!(
        composed.text, user_id: @user.id, correlation_id: "query:plan-#{SecureRandom.hex(2)}",
        pending_question: composed.pending, expected_episode_id: session.live_episode_id
      )
    end
    composed
  end

  def tool_client(move, observations, target = nil)
    input = {
      "move" => move,
      "assertions" => [],
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => target
    }
    Struct.new(:input) do
      def converse(_params)
        tool = Struct.new(:name, :input).new(Rag::TurnInterpreter::TOOL_NAME, input)
        block = Struct.new(:tool_use).new(tool)
        message = Struct.new(:content).new([ block ])
        output = Struct.new(:message).new(message)
        usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
        Struct.new(:output, :usage).new(output, usage)
      end
    end.new(input)
  end
end
