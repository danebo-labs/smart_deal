# frozen_string_literal: true

require 'test_helper'

class RagControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TEST_SESSION_ID = 'test-session-123'
  TEST_QUESTION = 'What is S3?'
  TEST_ANSWER = 'This is a test answer about S3'

  setup do
    @user = users(:one)
  end

  def with_mock_orchestrator(mock_orchestrator)
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_args, **_kwargs| mock_orchestrator }
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  def create_mock_orchestrator(answer:, citations: [], session_id: TEST_SESSION_ID,
                               should_raise: false, error_class: StandardError, error_message: nil,
                               documents_uploaded: nil)
    mock = Object.new
    mock.define_singleton_method(:execute) do
      raise error_class, error_message || 'Service error' if should_raise

      result = {
        answer: answer,
        citations: citations,
        session_id: session_id
      }
      result[:documents_uploaded] = documents_uploaded if documents_uploaded.present?
      result
    end
    mock
  end

  test 'requires authentication' do
    post rag_ask_url, params: { question: 'test question' }, as: :json
    assert_response :unauthorized
    json = json_response
    assert json.key?('error')
  end

  test 'rejects empty question when no attachments' do
    sign_in @user
    post rag_ask_url, params: { question: '' }, as: :json
    assert_response :bad_request

    json = json_response
    assert_equal 'error', json['status']
    assert_includes json['message'].downcase, 'empty'
  end

  test 'accepts document with empty question and returns success' do
    sign_in @user

    mock = create_mock_orchestrator(
      answer: I18n.t('rag.document_indexing_message', locale: :es),
      citations: [],
      session_id: nil,
      documents_uploaded: ['test.txt']
    )

    with_mock_orchestrator(mock) do
      post rag_ask_url,
           params: {
             question: '',
             document: {
               data: Base64.strict_encode64('Hello world'),
               media_type: 'text/plain',
               filename: 'test.txt'
             }
           },
           as: :json
      assert_response :success

      json = json_response
      assert_equal 'success', json['status']
      assert_equal ['test.txt'], json['documents_uploaded']
      assert_includes json['answer'], 'procesado'
    end
  end

  test 'document upload returns Spanish message when Accept-Language is es' do
    sign_in @user

    mock = create_mock_orchestrator(
      answer: I18n.t('rag.document_indexing_message', locale: :es),
      citations: [],
      session_id: nil,
      documents_uploaded: ['archivo.txt']
    )

    with_mock_orchestrator(mock) do
      post rag_ask_url,
           params: {
             question: '',
             document: {
               data: Base64.strict_encode64('contenido'),
               media_type: 'text/plain',
               filename: 'archivo.txt'
             }
           },
           headers: { "HTTP_ACCEPT_LANGUAGE" => "es" },
           as: :json
      assert_response :success

      json = json_response
      assert_includes json["answer"], "Tu documento está siendo procesado"
    end
  end

  test 'document upload returns English message when Accept-Language is en' do
    sign_in @user

    mock = create_mock_orchestrator(
      answer: I18n.t('rag.document_indexing_message', locale: :en),
      citations: [],
      session_id: nil,
      documents_uploaded: ['file.txt']
    )

    with_mock_orchestrator(mock) do
      post rag_ask_url,
           params: {
             question: '',
             document: {
               data: Base64.strict_encode64('content'),
               media_type: 'text/plain',
               filename: 'file.txt'
             }
           },
           headers: { "HTTP_ACCEPT_LANGUAGE" => "en" },
           as: :json
      assert_response :success

      json = json_response
      assert_includes json["answer"], "Your document is being processed"
    end
  end

  test 'document upload uses default locale (es) when Accept-Language is absent' do
    sign_in @user

    mock = create_mock_orchestrator(
      answer: I18n.t('rag.document_indexing_message', locale: :es),
      citations: [],
      session_id: nil,
      documents_uploaded: ['doc.txt']
    )

    with_mock_orchestrator(mock) do
      post rag_ask_url,
           params: {
             question: '',
             document: {
               data: Base64.strict_encode64('texto'),
               media_type: 'text/plain',
               filename: 'doc.txt'
             }
           },
           as: :json
      assert_response :success

      json = json_response
      assert_includes json["answer"], "Tu documento está siendo procesado"
    end
  end

  test 'returns successful response with answer and citations' do
    sign_in @user

    citations = [{ filename: 'test.pdf', title: 'Test Document' }]

    mock = create_mock_orchestrator(
      answer: TEST_ANSWER,
      citations: citations,
      session_id: TEST_SESSION_ID
    )

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      assert_response :success

      json = json_response
      assert_equal 'success', json['status']
      assert_equal TEST_ANSWER, json['answer']
      assert_equal TEST_SESSION_ID, json['session_id']
      assert json.key?('citations')
      assert json['citations'].is_a?(Array)
      assert_equal 1, json['citations'].length
      assert_equal 'test.pdf', json['citations'].first['filename']
      assert_equal 'Test Document', json['citations'].first['title']
    end
  end

  test 'handles MissingKnowledgeBaseError gracefully' do
    sign_in @user

    mock = create_mock_orchestrator(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::MissingKnowledgeBaseError,
      error_message: 'Knowledge Base ID not configured'
    )

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: 'test question' }, as: :json
      assert_response :internal_server_error

      json = json_response
      assert_equal 'error', json['status']
      assert_equal 'RAG service is not properly configured', json['message']
    end
  end

  test 'handles BedrockServiceError gracefully' do
    sign_in @user

    mock = create_mock_orchestrator(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::BedrockServiceError,
      error_message: 'Failed to query Knowledge Base'
    )

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: 'test question' }, as: :json
      assert_response :bad_gateway

      json = json_response
      assert_equal 'error', json['status']
      assert_equal 'Error querying knowledge base', json['message']
    end
  end

  test 'handles unexpected StandardError gracefully' do
    sign_in @user

    mock = create_mock_orchestrator(
      answer: '',
      should_raise: true,
      error_class: StandardError,
      error_message: 'Unexpected error'
    )

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: 'test question' }, as: :json
      assert_response :internal_server_error

      json = json_response
      assert_equal 'error', json['status']
      assert_equal 'Unexpected error processing request', json['message']
    end
  end

  test 'returns no_results message in Spanish when Accept-Language is es' do
    sign_in @user

    # Mock returns I18n.t which uses the locale set by set_locale before_action
    mock = Object.new
    mock.define_singleton_method(:execute) do
      { answer: I18n.t("rag.no_results_found"), citations: [], session_id: nil }
    end

    with_mock_orchestrator(mock) do
      post rag_ask_url,
           params: { question: '¿Qué es EC2?' },
           headers: { "HTTP_ACCEPT_LANGUAGE" => "es" },
           as: :json
      assert_response :success

      json = json_response
      assert_equal "success", json["status"]
      assert_includes json["answer"], "No se encontró información"
    end
  end

  test 'returns no_results message in English when Accept-Language is en' do
    sign_in @user

    mock = Object.new
    mock.define_singleton_method(:execute) do
      { answer: I18n.t("rag.no_results_found"), citations: [], session_id: nil }
    end

    with_mock_orchestrator(mock) do
      post rag_ask_url,
           params: { question: "What is EC2?" },
           headers: { "HTTP_ACCEPT_LANGUAGE" => "en" },
           as: :json
      assert_response :success

      json = json_response
      assert_equal "success", json["status"]
      assert_includes json["answer"], "No information was found"
    end
  end

  # ─── Session / history / entity wiring ─────────────────────────────────────

  test 'ask creates a web ConversationSession for current_user' do
    sign_in @user

    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: [])

    assert_difference 'ConversationSession.where(channel: "web").count', 1 do
      with_mock_orchestrator(mock) do
        post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      end
    end
  end

  test 'ask reuses existing web session for the same user' do
    sign_in @user

    ConversationSession.find_or_create_for(
      identifier: @user.id.to_s,
      channel:    'web',
      user_id:    @user.id
    )

    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: [])

    assert_no_difference 'ConversationSession.count' do
      with_mock_orchestrator(mock) do
        post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      end
    end
  end

  test 'ask adds user and assistant messages to conversation_history' do
    sign_in @user

    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: [])

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
    end

    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: 'web')
    assert session.present?

    history = session.conversation_history
    assert history.any? { |h| h['role'] == 'user' && h['content'].include?(TEST_QUESTION) }
    assert history.any? { |h| h['role'] == 'assistant' }
  end

  test 'ask calls EntityExtractor and populates active_entities from citations' do
    sign_in @user

    citations = [ { number: 1, filename: 'guide.pdf', title: 'Guide' } ]
    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: citations)

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
    end

    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: 'web')
    assert session.active_entities.key?('guide.pdf')
    assert_equal 'citation_filename_fallback', session.active_entities['guide.pdf']['source']
  end

  test 'ask registers entity via fallback when citations empty but answer valid and question has filename' do
    sign_in @user

    mock = create_mock_orchestrator(
      answer:    'Es un diagrama técnico de circuito de seguridad.',
      citations: [],
      session_id: TEST_SESSION_ID
    )

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: 'que es circuito2_.jpeg ?' }, as: :json
    end

    assert_response :success
    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: 'web')
    assert session.active_entities.key?('circuito2_.jpeg'),
           'Filename from question should be registered via fallback'
  end

  test 'ask does NOT register entity when answer is no-results guardrail' do
    sign_in @user

    guardrail = 'No se encontró información sobre tu consulta. Sube un archivo...'
    mock = create_mock_orchestrator(answer: guardrail, citations: [], session_id: nil)

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: 'que es schema.pdf ?' }, as: :json
    end

    assert_response :success
    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: 'web')
    assert_equal 0, session.entity_count,
                 'No entity should be registered when answer is guardrail'
  end

  private

  def json_response
    JSON.parse(@response.body)
  end
end
