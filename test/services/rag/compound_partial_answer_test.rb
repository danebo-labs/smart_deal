# frozen_string_literal: true

require "test_helper"
require_relative "../../support/companion_plan_response"

class Rag::CompoundPartialAnswerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  PART = "¿Hay una señal de parada (#14) activa?"
  COMPOUND = "¿Está disparado el térmico o hay una señal de parada (#14) activa?"
  LIGHT = "¿El indicador encendido es el de marcha o el de fallo?"
  MANUAL = <<~TEXT
    • El compresor se detiene solo.
    – Comprobar que el térmico no esté disparado.
    – Comprobar si hay una señal de parada (#14) activa.
    • Marcha.
    El indicador de marcha está encendido cuando la marcha está activa.
    • Fallo.
    El indicador de fallo está encendido cuando hay un fallo.
    • La válvula no abre.
    – Comprobar si la válvula está abierta.
  TEXT
  UNKNOWN = "No sé cómo saber si está activa la entrada #14 ni si hay un contacto cerrado entre #14 y #16."

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
  end

  test "a checked part and an unknown on the designated part settle the compound question" do
    with_flags do
      session = started
      publish(session, COMPOUND, "El compresor se detiene solo.")
      publish(session, LIGHT, "Marcha.")
      turn(session, "Revisé el térmico y no está disparado.", "report", [ "no está disparado" ],
        checks: [ { "subject" => "el térmico", "status" => "done", "result" => "no está disparado" } ])
      kept = episode(session)
      assert_equal COMPOUND, kept.pending_question["question"]
      assert kept.observations.none? { |item| item.dig("answers", "q").present? }

      turn(session, UNKNOWN, "answer_pending", [ UNKNOWN.delete_suffix(".") ], resolution: "unknown")
      state = episode(session)
      limit = state.observations.find { |item| item.dig("answers", "r") == "unknown" }
      assert_equal PART, limit.dig("answers", "q")
      assert state.observations.none? { |item| item.dig("answers", "r") == "no" }
      assert_equal LIGHT, state.pending_question["question"]
      assert_equal "done", state.checks.find { |item| item["subject"] == "el térmico" }["status"]
    end
  end

  test "an unknown on the designated part does not close a part nobody checked" do
    with_flags do
      session = started
      publish(session, COMPOUND, "El compresor se detiene solo.")
      turn(session, UNKNOWN, "report", [ UNKNOWN.delete_suffix(".") ])
      state = episode(session)
      limit = state.observations.find { |item| item.dig("answers", "r") == "unknown" }
      assert_equal PART, limit.dig("answers", "q")
      assert_equal COMPOUND, state.pending_question["question"]
      assert state.checks.none? { |item| item["subject"].to_s.include?("térmico") }
    end
  end

  test "a number shared with another connection, component, or property is not the part" do
    question = { "question" => COMPOUND, "targets" => [ { "item" => "El compresor se detiene solo." } ] }
    input = { "question" => "¿Está disparado el térmico o la entrada de parada (#14) está activa?", "targets" => [] }

    assert_nil Rag::WorkContextReducer.answered_part(input, "No sé si la salida #14 está activa.")
    assert_nil Rag::WorkContextReducer.answered_part(question, "No sé si la válvula #14 está activa.")
    assert_nil Rag::WorkContextReducer.answered_part(question, "No sé dónde está la entrada #14.")
    assert_nil Rag::WorkContextReducer.answered_part(question, "No sé si la entrada #14 está cerrada.")
    assert_nil Rag::WorkContextReducer.answered_part(question, "No sé si el térmico está disparado.")
    assert Rag::WorkContextReducer.answered_part(question, "No sé si la entrada #14 está activa.")
    assert Rag::WorkContextReducer.answered_part(input, "No sé si la entrada #14 está activa.")
    single = { "question" => "¿La válvula está abierta?", "targets" => [ { "item" => "Válvula." } ] }
    assert_nil Rag::WorkContextReducer.answered_part(single, "No sé si la compuerta 3 está abierta")
    assert_not Rag::WorkContextReducer.same_published_datum?(single, "No sé si la compuerta está abierta")
  end

  test "a reply that fits the designated part and the shown clarification stays unbound" do
    with_flags do
      session = started
      publish(session, COMPOUND, "El compresor se detiene solo.")
      publish(session, "¿Está activa la entrada #14 o la entrada #16?", "El compresor se detiene solo.")
      held = episode(session)
      assert_equal COMPOUND, held.pending_question["question"]
      assert held.pending_question["shown"].present?

      turn(session, "No sé si la entrada #14 está activa.", "report", [ "No sé si la entrada #14 está activa" ])
      state = episode(session)
      assert state.observations.none? { |item| item.dig("answers", "q").present? }
      assert_equal COMPOUND, state.pending_question["question"]
    end
  end

  private

  def started
    session = ConversationSession.create!(
      identifier: "web:partial-#{SecureRandom.hex(3)}", channel: "web", expires_at: 1.hour.from_now,
      user: @user, account: @account, active_episode: {}, conversation_history: []
    )
    turn(session, "El compresor se detiene solo.", "report", [ "El compresor se detiene solo." ])
    session
  end

  def episode(session)
    Rag::ActiveEpisode.parse(session.reload.active_episode)
  end

  def turn(session, text, move, observations, checks: [], resolution: nil)
    session.record_user_turn!(
      text, user_id: @user.id, correlation_id: "query:#{SecureRandom.hex(4)}",
      interpreter_client: tool_client(move, observations, checks, resolution)
    )
  end

  def publish(session, question, item_text)
    chunks = [ {
      content: MANUAL,
      metadata: { "page_number" => "3", "original_source_uri" => "s3://fixture/compressor.pdf", "filename" => "chunk_p3_1.txt" },
      identity_applicability: "compatible"
    } ]
    prepared = Rag::CompanionPlan.prepare(
      raw_question: question, chunks: chunks, episode: episode(session), session: session, correlation_id: "query:plan"
    )
    item = prepared.statements.statements.find { |row| row.kind == "item" && row.text.include?(item_text) }
    steps = prepared.statements.statements.select(&:step?).map(&:id)
    composed = Rag::CompanionPlan.compose(
      CompanionPlanResponse.build({ "links" => [], "steps" => steps, "question" => question, "question_about" => [ item.id ] }),
      prepared
    )
    assert_equal question, composed.check.question, composed.check.rejections.inspect
    session.record_assistant_turn!(
      composed.text, user_id: @user.id, correlation_id: "query:plan-#{SecureRandom.hex(2)}",
      pending_question: composed.pending, expected_episode_id: session.live_episode_id
    )
  end

  def with_flags
    previous = [ ENV["HAIKU_QUERY_ANALYSIS_MODE"], ENV["FIELD_COMPANION_EPISODE_ENABLED"] ]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    assert_no_enqueued_jobs(only: TrackBedrockQueryJob) { yield }
  ensure
    ENV["HAIKU_QUERY_ANALYSIS_MODE"], ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous
  end

  def tool_client(move, observations, checks, resolution)
    input = {
      "move" => move, "assertions" => [], "observations" => observations, "checks" => checks,
      "pending_resolution" => resolution, "clarification_target" => nil
    }
    Struct.new(:input) do
      def converse(_params)
        tool = Struct.new(:name, :input).new(Rag::TurnInterpreter::TOOL_NAME, input)
        message = Struct.new(:content).new([ Struct.new(:tool_use).new(tool) ])
        usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
        Struct.new(:output, :usage).new(Struct.new(:message).new(message), usage)
      end
    end.new(input)
  end
end
