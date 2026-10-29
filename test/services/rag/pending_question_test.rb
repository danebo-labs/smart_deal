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

  test "a conversational target is stored without a fact and is not parsed from prose" do
    question = { "type" => "work_relation", "carry" => [ "Q2" ] }
    state = Rag::ActiveEpisodeTurn.apply_assistant(
      state: episode_state, text: "¿Esto sigue siendo el mismo equipo?", now: NOW, correlation_id: "query:rel",
      pending_question: question
    ).state

    assert_equal question, state["pending_question"]
    assert_nil state["pending_fact"]
    assert_nil Rag::PendingQuestion.parse_reply("Es otro ascensor", pending_question: question)
    assert_nil Rag::PendingQuestion.coerce("type" => "work_relation", "options" => [ "same" ])["options"]
  end

  test "a longer no se answers the documented question and a negated state does not" do
    question = {
      "type" => "documented_context",
      "question" => "¿El LED se enciende por la entrada 21 o por la fotocélula?",
      "targets" => [ { "item" => "Fotocélula.", "document_key" => "s3://x", "filename" => "chunk_p7_3.txt", "page" => "7" } ]
    }
    reply = Rag::PendingQuestion.parse_reply(
      "No sé cómo distinguir si lo activa la entrada 21 o la fotocélula",
      pending_question: question
    )
    assert_equal({ "type" => "documented_context", "r" => "unknown" }, reply)
    assert_nil Rag::PendingQuestion.parse_reply("No se enciende el LED", pending_question: question)
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
    service = Rails.root.join("app/services/bedrock_rag_service.rb").read
    assert_includes service, "pending_question"
    assert_not_includes service, "PendingQuestion.parse_reply"
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

  test "both the open question and the clarification count when the text has both" do
    text = "#{entry_question}\n#{indicator_question}"
    assert_equal held_question, Rag::PendingQuestion.presented(held_question, text, retained: open_question)
  end

  test "a clarification published alone keeps the open question already stored" do
    kept = Rag::PendingQuestion.presented(held_question, indicator_question, retained: open_question)
    assert_equal held_question, kept
    assert_equal indicator_question, kept.dig("shown", "question")
  end

  test "a clarification absent from the text is not stored as shown" do
    assert_nil Rag::PendingQuestion.presented(held_question, "texto sin preguntas", retained: open_question)
    kept = Rag::PendingQuestion.presented(held_question, entry_question, retained: open_question)
    assert_equal open_question, kept
    assert_nil kept["shown"]
  end

  test "a question that was not stored and did not reach the text is not kept through its clarification" do
    assert_nil Rag::PendingQuestion.presented(held_question, indicator_question, retained: nil)
    other = open_question.merge("question" => "¿Otra pregunta?")
    assert_nil Rag::PendingQuestion.presented(held_question, indicator_question, retained: other)
  end

  test "a clarification already stored stays when the same datum is reworded and published" do
    reworded = held_question.merge("question" => "¿La entrada A está activa?")
    assert_equal reworded, Rag::PendingQuestion.presented(reworded, "¿La entrada A está activa?", retained: held_question)
    assert_nil Rag::PendingQuestion.presented(reworded, indicator_question, retained: held_question)
  end

  test "a clarification withdrawn from the final answer is not stored even though the proposal had it" do
    proposal_text = "Orientación.\n#{entry_question}\n#{indicator_question}"
    final_answer = "Orientación.\n#{entry_question}"
    assert_includes proposal_text, indicator_question
    assert_not_includes final_answer, indicator_question

    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_plan_pending, held_question)
    service.instance_variable_set(:@companion_plan_retained, open_question)
    published_proposal = service.send(:companion_turn_pending, true, proposal_text)
    assert_equal indicator_question, published_proposal.dig("shown", "question")
    withdrawn = service.send(:companion_turn_pending, true, final_answer)
    assert_equal open_question, withdrawn
    assert_nil withdrawn["shown"]
    assert_nil service.send(:companion_turn_pending, true, "Orientación sin preguntas.")
    assert_nil service.send(:companion_turn_pending, false, proposal_text)

    only_clarification = "Orientación.\n#{indicator_question}"
    kept = service.send(:companion_turn_pending, true, only_clarification)
    assert_equal entry_question, kept["question"]
    assert_equal indicator_question, kept.dig("shown", "question")

    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: NOW)
    episode.assign_goal!("el conjunto no responde", correlation_id: "query:open")
    episode.pending_question = open_question
    session = Struct.new(:active_episode).new(episode.to_h)
    host = Object.new.extend(RagQueryConcern)
    final = publication(final_answer, final_answer)
    published = host.send(:companion_published_pending, held_question, final, session)
    assert_equal open_question, published
    assert_nil published["shown"]

    history_drops_it = publication(proposal_text, final_answer)
    from_history = host.send(:companion_published_pending, held_question, history_drops_it, session)
    assert_equal open_question, from_history
    assert_nil from_history["shown"]

    abstained = publication(proposal_text, "", route_outcome: :abstained, companion_reason: "companion_contract_invalid")
    assert_nil host.send(:companion_published_pending, held_question, abstained, session)
  end

  private

  def entry_question
    "¿Está activada la entrada A?"
  end

  def indicator_question
    "¿Cuál indicador está encendido, X o Y?"
  end

  def entry_target
    [ { "item" => "Conjunto.", "document_key" => "doc", "filename" => "p12.txt", "page" => "12" } ]
  end

  def indicator_targets
    [
      { "item" => "Indicador X.", "document_key" => "doc", "filename" => "p7.txt", "page" => "7" },
      { "item" => "Indicador Y.", "document_key" => "doc", "filename" => "p7.txt", "page" => "7" }
    ]
  end

  def open_question
    Rag::PendingQuestion.coerce(
      "type" => "documented_context", "question" => entry_question, "targets" => entry_target
    )
  end

  def held_question
    open_question.merge("shown" => { "question" => indicator_question, "targets" => indicator_targets })
  end

  def publication(presented, history, route_outcome: :answered, companion_reason: nil)
    RagQueryConcern::CompanionPublication.new(
      presented: presented, history: history, route_outcome: route_outcome, companion_reason: companion_reason
    )
  end

  def episode_state
    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: NOW)
    episode.assign_goal!("ruido al abrir", correlation_id: "query:open")
    episode.to_h
  end
end
