# frozen_string_literal: true

require "test_helper"

class Rag::PendingQuestionTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 9, 25, 15, 0, 0)

  test "fault_code manufacturer and model round-trip and win over prose" do
    state = episode_state
    fault = Rag::ActiveEpisodeTurn.apply_assistant(
      state: state, text: "¿Cuál es la marca?", now: NOW, correlation_id: "query:a",
      pending_question: { "type" => "fault_code" }
    )
    assert_equal "fault_code", fault.state.dig("pending_question", "type")
    assert_equal "fault_code", fault.state.dig("pending_fact", "subject")

    model = Rag::ActiveEpisodeTurn.apply_assistant(
      state: state, text: "¿Cuál es el código?", now: NOW, correlation_id: "query:b",
      pending_question: { "type" => "model" }
    )
    assert_equal "model", model.state.dig("pending_question", "type")
    assert_equal "model", model.state.dig("pending_fact", "subject")

    brand = Rag::ActiveEpisodeTurn.apply_assistant(
      state: state, text: "sin pregunta", now: NOW, correlation_id: "query:c",
      pending_question: { "type" => "manufacturer" }
    )
    assert_equal "manufacturer", brand.state.dig("pending_question", "type")
    assert_equal "manufacturer", brand.state.dig("pending_fact", "subject")
  end

  test "choice options round-trip and al abrir selects opening" do
    question = { "type" => "choice", "options" => %w[opening closing] }
    state = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: "¿Al abrir o al cerrar?", now: NOW, correlation_id: "query:choice",
      pending_question: question
    ).state
    assert_equal question, state["pending_question"]
    assert_nil state["pending_fact"]

    answered = Rag::ActiveEpisodeTurn.call(
      state: state, text: "al abrir", now: NOW, enabled: true, shared: false, correlation_id: "query:reply"
    )
    assert_nil answered.state["pending_question"]
    assert_nil answered.state.dig("facts", "fault_code")
    assert_equal({ "type" => "choice", "value" => "opening" }, Rag::PendingQuestion.parse_reply("al abrir", pending_question: question))
  end

  test "ninguno on a fault_code question confirms absence" do
    state = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: "¿Qué código muestra?", now: NOW, correlation_id: "query:code",
      pending_question: { "type" => "fault_code" }
    ).state
    answered = Rag::ActiveEpisodeTurn.call(
      state: state, text: "ninguno", now: NOW, enabled: true, shared: false, correlation_id: "query:none"
    )
    assert_equal "absent_confirmed", answered.state.dig("facts", "fault_code", "status")
    assert_nil answered.state["pending_question"]
  end

  test "prose fallback still sets the subject when no structured object is passed" do
    result = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: "¿Sabes el modelo del equipo?", now: NOW, correlation_id: "query:prose"
    )
    assert_nil result.state["pending_question"]
    assert_equal "model", result.state.dig("pending_fact", "subject")
  end

  test "the assistant answer text is not rewritten when a pending question is stored" do
    prose = "Ajusta el freno según el manual. [1]"
    result = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: prose, now: NOW, correlation_id: "query:cite",
      pending_question: { "type" => "fault_code" }
    )
    assert_equal "fault_code", result.state.dig("pending_question", "type")
    assert_not_includes JSON.generate(result.state), prose
    assert_not_includes Rails.root.join("app/services/bedrock_rag_service.rb").read, "pending_question"
  end

  test "a pending question does not evict identifiers inside the 2048-byte budget" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:budget", now: NOW)
    episode.assign_goal!("cómo se ajustan los resortes", correlation_id: "query:budget")
    episode.write_fact!("manufacturer", status: "known", value: "Otis", source: "user", correlation_id: "query:budget", at: NOW.iso8601)
    episode.write_fact!("model", status: "known", value: "MonoSpace", source: "user", correlation_id: "query:budget", at: NOW.iso8601)
    5.times { |index| episode.append_identifier!("ID#{index}TOKEN", correlation_id: "query:budget") }
    before = episode.to_h
    stored = Rag::ActiveEpisodeTurn.apply_assistant(
      state: before, text: "¿Qué código?", now: NOW, correlation_id: "query:budget",
      pending_question: { "type" => "fault_code" }
    ).state
    assert_equal before["identifiers"], stored["identifiers"]
    assert_equal before["facts"], stored["facts"]
    assert_operator JSON.generate(stored).bytesize, :<=, Rag::ActiveEpisode::MAX_BYTES
  end

  private

  def episode_state
    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: NOW)
    episode.assign_goal!("ruido al abrir", correlation_id: "query:open")
    episode.to_h
  end
end
