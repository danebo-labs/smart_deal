# frozen_string_literal: true

require "test_helper"

class Rag::PhotoQuestionAnswerServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @account = accounts(:legacy)
    @session = ConversationSession.create!(
      identifier: "photo-question-service",
      channel: "web",
      account: @account,
      user: users(:one),
      expires_at: 1.day.from_now
    )
    @photo_value = {
      canonical_name: "GECB",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "GOOD",
      visible_codes: [ "System=1", "Tools=2", "UNKNOWN" ]
    }
    @previous_flag = ENV.fetch("PHOTO_QUESTION_RAG_ENABLED", nil)
    @previous_sources_flag = ENV.fetch("SHOW_RAG_SOURCES", nil)
    ENV["PHOTO_QUESTION_RAG_ENABLED"] = "true"
    ENV["SHOW_RAG_SOURCES"] = "true"
    @orig_rag_query = BedrockRagService.instance_method(:query)
  end

  teardown do
    BedrockRagService.define_method(:query, @orig_rag_query)
    @previous_flag.nil? ? ENV.delete("PHOTO_QUESTION_RAG_ENABLED") : ENV["PHOTO_QUESTION_RAG_ENABLED"] = @previous_flag
    @previous_sources_flag.nil? ? ENV.delete("SHOW_RAG_SOURCES") : ENV["SHOW_RAG_SOURCES"] = @previous_sources_flag
  end

  test "anchors the question with the visible component and codes, omitting UNKNOWN" do
    captured = nil
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured = { question: question, kwargs: kwargs }
      { answer: "Es un GECB [1]", citations: [ { number: 1, title: "Manual" } ], session_id: nil }
    end

    result = build_service(question: "Que equipo es y que está mostrando la pantalla?").call

    assert_includes captured[:question], "Que equipo es y que está mostrando la pantalla?"
    assert_includes captured[:question], "GECB"
    assert_includes captured[:question], "System=1"
    assert_includes captured[:question], "Tools=2"
    assert_not_includes captured[:question], "UNKNOWN"
    assert result
    assert_equal "Es un GECB [1]", result[:answer]
  end

  test "session_context carries the Photo Evidence block within the cap" do
    captured = nil
    BedrockRagService.define_method(:query) do |_question, **kwargs|
      captured = kwargs
      { answer: "ok", citations: [], session_id: nil }
    end

    build_service(question: "Que está mostrando la pantalla?").call

    context = captured[:session_context]
    assert_includes context, "## Photo Evidence (this turn)"
    assert_includes context, "Component: GECB"
    assert_includes context, "Visible text/codes: System=1, Tools=2, UNKNOWN"
    assert_operator context.length, :<=, 2600
  end

  test "forced response_locale overrides text-based detection" do
    captured = nil
    BedrockRagService.define_method(:query) do |_question, **kwargs|
      captured = kwargs
      { answer: "ok", citations: [], session_id: nil }
    end

    build_service(question: "Instalar", locale: "en").call

    assert_equal :en, captured[:response_locale]
  end

  test "citations are normalized through Bedrock::CitationProcessor" do
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      {
        answer: "Respuesta [1]",
        citations: [ { number: 1, title: "Manual", content: "chunk body text" } ],
        session_id: nil
      }
    end

    result = build_service(question: "Que es esto?").call

    assert_equal 1, result[:citations].size
    citation = result[:citations].first
    assert_not citation.key?(:content), "raw chunk content must not reach the browser"
    assert citation[:tooltip_excerpt].present?
  end

  test "returns nil when the flag is off" do
    ENV.delete("PHOTO_QUESTION_RAG_ENABLED")

    result = build_service(question: "Que es esto?").call

    assert_nil result
  end

  test "returns nil for a blank question" do
    result = build_service(question: "   ").call

    assert_nil result
  end

  test "returns nil when the RAG call does not succeed" do
    BedrockRagService.define_method(:query) do |*|
      raise BedrockRagService::BedrockServiceError, "boom"
    end

    result = build_service(question: "Que es esto?").call

    assert_nil result
  end

  private

  def build_service(question:, locale: "es")
    Rag::PhotoQuestionAnswerService.new(
      question: question,
      photo_value: @photo_value,
      session: @session,
      account: @account,
      user_id: users(:one).id,
      correlation_id: "photo:test",
      locale: locale
    )
  end
end
