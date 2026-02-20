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
    QueryOrchestratorService.define_singleton_method(:new) { |*_args| mock_orchestrator }
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  def create_mock_orchestrator(answer:, citations: [], session_id: TEST_SESSION_ID,
                               should_raise: false, error_class: StandardError, error_message: nil)
    mock = Object.new
    mock.define_singleton_method(:execute) do
      raise error_class, error_message || 'Service error' if should_raise

      {
        answer: answer,
        citations: citations,
        session_id: session_id
      }
    end
    mock
  end

  test 'requires authentication' do
    post rag_ask_url, params: { question: 'test question' }, as: :json
    assert_response :unauthorized
    json = json_response
    assert json.key?('error')
  end

  test 'rejects empty question' do
    sign_in @user
    post rag_ask_url, params: { question: '' }, as: :json
    assert_response :bad_request

    json = json_response
    assert_equal 'error', json['status']
    assert_includes json['message'].downcase, 'empty'
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

  private

  def json_response
    JSON.parse(@response.body)
  end
end
