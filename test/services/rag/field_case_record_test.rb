# frozen_string_literal: true

require "test_helper"
require "digest"

class Rag::FieldCaseRecordTest < ActiveSupport::TestCase
  # Bytes of FIELD_REPORT_PARAGRAPH after the orientation substitution.
  PARAGRAPH_SHA = "0992a841c2e7f9ef0c5a417753c449eae5a232df90c7926c7e2685d0d1e0f2a6"
  TEMPLATE_SHA = "cc875e4132b4391d2d581fe50e37170a3da302bca0432cc81343af1d6f4c9a39"
  GENERATION_FILE_SHA = "1844024b18bb9c373c8e42e0617e32cde68166c85ad0345ac51f495f9b9e1638"
  REMOVED = "State the documented checks that fit the report, with their conditions, and which remain open. You may suggest which open check to do next, with the reason taken from the report, as your own orientation and not as an order or likelihood the passages do not state."
  ADDED = "The Active Field Problem record is shown to the technician with your answer; do not restate whether a check is done or open. State the documented checks that fit the report with the passage's own verb and condition. Then give one next observation or check as your own orientation, with its reason taken from the report and the passages, not as an order or likelihood the passages do not state, and ask at most one question."

  class ProbeController
    include RagQueryConcern
    attr_accessor :current_account
  end

  test "the field report paragraph replaces the two orientation sentences once" do
    paragraph = BedrockRagService::FIELD_REPORT_PARAGRAPH
    contract = BedrockRagService::DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT

    assert_equal PARAGRAPH_SHA, Digest::SHA256.hexdigest(paragraph)
    assert_equal 1, paragraph.scan(ADDED).size
    assert_not_includes paragraph, REMOVED
    assert_not_includes paragraph, "which remain open"
    assert_includes paragraph, "leaves the documentary check about that thing open"
    assert_includes paragraph, "Do not replace those checks with a refusal"
    assert_equal 1, contract.scan(paragraph).size
    template = with_env("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil) do
      BedrockRagService.load_generation_prompt_template
    end
    assert_equal TEMPLATE_SHA, Digest::SHA256.hexdigest(template)
    assert_equal GENERATION_FILE_SHA, Digest::SHA256.file(
      Rails.root.join("app/prompts/bedrock/generation.txt")
    ).hexdigest
    assert_not_includes BedrockRagService.load_generation_prompt_template, ADDED
  end

  test "quotes the stored fragments and leaves a missing result empty" do
    episode = turn_episode
    episode.append_observation!("no está activada", correlation_id: "case")
    episode.upsert_check!(
      { "subject" => "fotocélula", "status" => "done" },
      correlation_id: "case"
    )
    episode.upsert_check!(
      { "subject" => "el #54", "status" => "not_done" },
      correlation_id: "case"
    )
    before = episode.checks.map(&:dup)

    record = Rag::FieldCaseRecord.render(episode, generation_mode: "document_identity_scope")

    assert_equal before, episode.checks
    assert_nil episode.checks.find { |item| item["subject"] == "fotocélula" }["result"]
    assert_includes record, "Equipo: Fermator VF5+, Modo esclavo."
    assert_not_includes record, "Equipo: Fermator."
    assert_includes record, "Síntoma: «La puerta se reabre sola»."
    assert_includes record, "«El LED de fotocélula está apagado», «No veo obstrucción»"
    observations = record[/Observaciones: .*? Comprobaciones:/]
    assert_not_includes observations, "La puerta se reabre sola"
    assert_includes record, "«no está activada»"
    assert_includes record, "#54, sin hacer"
    assert_includes record, "mediciones, sin hacer"
    assert_includes record, "el #54, sin hacer"
    assert_includes record, "fotocélula, hecha, sin resultado registrado"
    assert_not_includes record, "pág"
    assert_not_includes record, "[1]"
    assert_not_includes record, "PDF"
    assert_not_includes record.downcase, "manual"
  end

  test "a done result is copied and a photo fact is not the equipment" do
    episode = turn_episode
    now = Time.current
    episode.write_fact!(
      "model", status: "known", value: "LeidoEnFoto", source: "photo",
      correlation_id: "case", at: now.iso8601
    )
    episode.upsert_check!(
      { "subject" => "fotocélula", "status" => "done", "result" => "no está activada" },
      correlation_id: "case"
    )

    record = Rag::FieldCaseRecord.render(episode, generation_mode: "document_identity_scope")

    assert_includes record, "fotocélula, hecha, «no está activada»"
    assert_not_includes record, "LeidoEnFoto"
    assert_not_includes record, "sin resultado registrado"
  end

  test "an empty episode and a non-identity answer stay without a record" do
    empty = Rag::ActiveEpisode.open(correlation_id: "case", now: Time.current)
    goal_only = Rag::ActiveEpisode.open(correlation_id: "case", now: Time.current)
    goal_only.assign_goal!("La puerta se reabre sola", correlation_id: "case")
    closed = turn_episode
    closed.status = "closed"

    [ empty, goal_only, closed, Rag::ActiveEpisode.new ].each do |episode|
      assert_equal "", Rag::FieldCaseRecord.render(episode, generation_mode: "document_identity_scope")
    end
    assert_equal "", Rag::FieldCaseRecord.render(turn_episode, generation_mode: "retrieve_and_generate")

    attached = Rag::FieldCaseRecord.attach(
      "Texto del modelo.",
      episode: turn_episode,
      generation_mode: "retrieve_and_generate"
    )
    assert_equal "Texto del modelo.", attached.presented
    assert_nil attached.history
  end

  test "the shown answer carries the record and the history copy does not" do
    episode = turn_episode
    attached = Rag::FieldCaseRecord.attach(
      "",
      episode: episode,
      generation_mode: "document_identity_scope"
    )
    assert attached.presented.start_with?("Registro del caso.")
    assert_equal "", attached.history

    prose = "# Título\n\nComprobar la fotocélula."
    shown = Rag::FieldCaseRecord.attach(prose, episode: episode, generation_mode: "document_identity_scope")
    assert shown.presented.start_with?("Registro del caso.")
    assert shown.presented.end_with?(prose)
    assert_equal prose, shown.history
    assert_not_includes shown.history, "Registro del caso"
  end

  test "a companion turn publishes the answer without the case record" do
    prose = "El cierre puede quedar pendiente [1]."
    attached = Rag::FieldCaseRecord.attach(
      prose,
      episode: turn_episode,
      generation_mode: "document_identity_scope",
      companion_turn: true
    )

    assert_equal prose, attached.presented
    assert_equal prose, attached.history
    assert_not_includes attached.presented, "Registro del caso"
  end

  test "document identity delivery prepends the record after sanitizing" do
    episode = turn_episode
    session = ConversationSession.create!(
      identifier: "web:case-record-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy),
      active_episode: episode.to_h,
      conversation_history: []
    )
    controller = ProbeController.new
    controller.current_account = accounts(:legacy)
    mock = Object.new
    mock.define_singleton_method(:execute) do
      {
        answer: "# Título\n\nComprobar la fotocélula.",
        citations: [],
        session_id: "session-1",
        generation_mode: "document_identity_scope"
      }
    end
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_args, **_kwargs| mock }

    result = controller.send(
      :execute_rag_query,
      "la puerta se reabre sola",
      conv_session: session,
      account: accounts(:legacy)
    )

    assert result.success?
    assert result.answer.start_with?("Registro del caso.")
    assert_includes result.answer, "Comprobar la fotocélula."
    assert_not_includes result.answer, "# Título"
    assert result.answer.end_with?(result.history_answer)
    assert_includes result.history_answer, "Comprobar la fotocélula."
    assert_not_includes result.history_answer, "Registro del caso"
    assert_not_includes result.history_answer, "# Título"
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) } if original
  end

  test "the next prompt reads the model text and not the case record" do
    model = "ORIENTACION #{'detalle ' * 40}"
    record = Rag::FieldCaseRecord.render(turn_episode, generation_mode: "document_identity_scope")
    presented = "#{record}\n\n#{model}"
    episode = turn_episode
    session = ConversationSession.create!(
      identifier: "web:case-history-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy),
      active_episode: episode.to_h,
      conversation_history: []
    )

    with_episode_flag do
      session.record_assistant_turn!(
        presented,
        user_id: users(:one).id,
        correlation_id: "query:case",
        expected_episode_id: episode.episode_id,
        prompt_reply: model
      )
    end

    session.reload
    stored = session.conversation_history.reverse.find { |row| row["role"] == "assistant" }
    assert stored["content"].start_with?("Registro del caso.")
    assert_equal model.truncate(ConversationSession::MAX_MSG_LENGTH), stored["prompt_reply"]
    assert_includes session.last_assistant_message, "Registro del caso."

    assistant = session.episode_prompt_history.find { |turn| turn[:role] == "assistant" }
    assert_equal model.truncate(ConversationSession::MAX_MSG_LENGTH), assistant[:content]
    context = SessionContextBuilder.build(session)
    assert_includes context, "Assistant: #{model.truncate(200)}"
    assert_not_includes context, "Registro del caso"
  end

  private

  def turn_episode
    now = Time.current
    episode = Rag::ActiveEpisode.open(correlation_id: "case", now: now)
    episode.assign_goal!("La puerta se reabre sola", correlation_id: "case")
    episode.write_fact!(
      "manufacturer", status: "known", value: "Fermator", source: "user",
      correlation_id: "case", at: now.iso8601
    )
    episode.append_identifier!("Fermator VF5+", correlation_id: "case", source: "user")
    episode.append_identifier!("Modo esclavo", correlation_id: "case", source: "user")
    episode.append_observation!("La puerta se reabre sola", correlation_id: "case")
    episode.append_observation!("El LED de fotocélula está apagado", correlation_id: "case")
    episode.append_observation!("No veo obstrucción", correlation_id: "case")
    episode.upsert_check!({ "subject" => "#54", "status" => "not_done" }, correlation_id: "case")
    episode.upsert_check!({ "subject" => "mediciones", "status" => "not_done" }, correlation_id: "case")
    episode
  end

  def with_episode_flag
    with_env("FIELD_COMPANION_EPISODE_ENABLED", "true") { yield }
  end

  def with_env(key, value)
    previous = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
  end
end
