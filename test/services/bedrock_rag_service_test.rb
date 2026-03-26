# frozen_string_literal: true

require 'test_helper'
require 'ostruct'

class BedrockRagServiceTest < ActiveSupport::TestCase
  # Disable parallelization for this test class because it manipulates
  # global constants (Aws) which can cause race conditions when running in parallel
  parallelize(workers: 1)

  TEST_KB_ID = 'test-kb-id'
  TEST_AWS_REGION = 'us-east-1'
  TEST_SESSION_ID = 'test-session-123'

  setup do
    # Set up test knowledge base ID to avoid initialization errors
    ENV['BEDROCK_KNOWLEDGE_BASE_ID'] = TEST_KB_ID
    ENV['AWS_REGION'] = TEST_AWS_REGION
    # Clean up BedrockQuery records between tests
    BedrockQuery.delete_all
  end

  teardown do
    ENV.delete('BEDROCK_KNOWLEDGE_BASE_ID')
    ENV.delete('AWS_REGION')
  end

  # Fake AWS BedrockAgentRuntime Client
  class FakeBedrockAgentRuntimeClient
    attr_accessor :retrieve_and_generate_response, :should_raise_error, :error_message
    attr_reader :last_retrieve_and_generate_params

    def initialize(*)
      @retrieve_and_generate_response = nil
      @should_raise_error = false
      @error_message = nil
      @last_retrieve_and_generate_params = nil
    end

    def retrieve_and_generate(params)
      @last_retrieve_and_generate_params = params
      if @should_raise_error
        # Raise a real instance of Aws::BedrockAgentRuntime::Errors::ServiceError
        # This will be properly caught by the service's rescue clause
        error_message = @error_message || 'AWS Error'
        raise Aws::BedrockAgentRuntime::Errors::ServiceError.new(nil, error_message)
      end

      @retrieve_and_generate_response || default_retrieve_and_generate_response
    end

    private

    def default_retrieve_and_generate_response
      ::OpenStruct.new(
        output: ::OpenStruct.new(
          text: 'This is a test answer about AWS S3.'
        ),
        citations: [
          ::OpenStruct.new(
            retrieved_references: [
              ::OpenStruct.new(
                content: ::OpenStruct.new(
                  text: 'Amazon S3 is a storage service that provides object storage...'
                ),
                location: ::OpenStruct.new(
                  s3_location: ::OpenStruct.new(
                    uri: 's3://bucket/documents/AWS-Certified-Solutions-Architect-v4.pdf'
                  )
                ),
                metadata: {}
              )
            ]
          )
        ],
        session_id: TEST_SESSION_ID
      )
    end
  end

  # Helper method to stub AWS BedrockAgentRuntime client
  def with_mock_bedrock_client(mock_retrieve_and_generate_response: nil, should_raise: false, error_message: nil)
    fake_agent_client = FakeBedrockAgentRuntimeClient.new
    fake_agent_client.retrieve_and_generate_response = mock_retrieve_and_generate_response if mock_retrieve_and_generate_response

    if should_raise
      fake_agent_client.should_raise_error = true
      fake_agent_client.error_message = error_message
    end

    original_agent_new = Aws::BedrockAgentRuntime::Client.method(:new)
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*_args| fake_agent_client }

    yield fake_agent_client
  ensure
    if original_agent_new
      Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args| original_agent_new.call(*args) }
    end
  end

  # Builds a fake retrieve_and_generate response with the given answer text.
  def fake_response(answer_text)
    ::OpenStruct.new(
      output: ::OpenStruct.new(text: answer_text),
      citations: [],
      session_id: TEST_SESSION_ID
    )
  end

  # Helper method to temporarily modify environment variables
  def with_env_vars(vars)
    original = {}
    vars.each do |key, value|
      original[key] = ENV.fetch(key, nil)
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    original.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  test 'query raises MissingKnowledgeBaseError when knowledge base ID is not configured' do
    # Stub credentials so knowledge_base_id is nil (service reads credentials first, then ENV)
    original_credentials = Rails.application.credentials
    stub_credentials = Object.new
    stub_credentials.define_singleton_method(:dig) do |*keys|
      return nil if keys == [:bedrock, :knowledge_base_id]
      original_credentials.dig(*keys)
    end
    original_credentials_method = Rails.application.method(:credentials)
    Rails.application.define_singleton_method(:credentials) { stub_credentials }
    begin
      with_env_vars('BEDROCK_KNOWLEDGE_BASE_ID' => nil) do
        with_mock_bedrock_client do
          service = BedrockRagService.new

          assert_raises(BedrockRagService::MissingKnowledgeBaseError) do
            service.query('Test question')
          end
        end
      end
    ensure
      Rails.application.define_singleton_method(:credentials, original_credentials_method)
    end
  end

  test 'query returns answer, citations, and session_id when successful' do
    with_mock_bedrock_client do
      service = BedrockRagService.new
      result = service.query('What is S3?')

      assert result.is_a?(Hash)
      assert result.key?(:answer)
      assert result.key?(:citations)
      assert result.key?(:session_id)
      assert result[:answer].is_a?(String)
      assert result[:citations].is_a?(Array)
      assert_equal TEST_SESSION_ID, result[:session_id]
    end
  end

  test 'query raises BedrockServiceError when AWS Bedrock raises ServiceError' do
    with_mock_bedrock_client(should_raise: true, error_message: 'AccessDeniedException: User is not authorized') do
      service = BedrockRagService.new

      assert_raises(BedrockRagService::BedrockServiceError) do
        service.query('Test question')
      end
    end
  end

  test 'query returns successful response even if metrics tracking fails' do
    with_mock_bedrock_client do
      service = BedrockRagService.new

      original_create = BedrockQuery.method(:create!)
      BedrockQuery.singleton_class.define_method(:create!) do |*_args|
        raise StandardError, 'Database error'
      end

      begin
        result = service.query('What is S3?')

        assert result.is_a?(Hash)
        assert result.key?(:answer)
        assert result.key?(:citations)
        assert result.key?(:session_id)
      ensure
        BedrockQuery.singleton_class.define_method(:create!, original_create)
      end
    end
  end

  test 'query replaces Bedrock no-results guardrail message with user-friendly I18n message' do
    bedrock_sorry = "Sorry, I am unable to assist you with this request."
    with_mock_bedrock_client(mock_retrieve_and_generate_response: fake_response(bedrock_sorry)) do
      service = BedrockRagService.new
      result = service.query('que es EC2')

      # Spanish question -> Spanish response (detected from question text)
      assert_includes result[:answer], 'No se encontró información'
      assert_equal [], result[:citations]
    end
  end

  test 'query returns English no-results message when question is in English' do
    bedrock_sorry = "Sorry, I am unable to assist you with this request."
    with_mock_bedrock_client(mock_retrieve_and_generate_response: fake_response(bedrock_sorry)) do
      service = BedrockRagService.new
      result = service.query('What is S3?')

      assert_includes result[:answer], 'No information was found'
      assert_equal [], result[:citations]
    end
  end

  test 'query uses response_locale for no-results message when question text looks Spanish' do
    bedrock_sorry = "Sorry, I am unable to assist you with this request."
    with_mock_bedrock_client(mock_retrieve_and_generate_response: fake_response(bedrock_sorry)) do
      service = BedrockRagService.new
      result = service.query('modernización', response_locale: :en)

      assert_includes result[:answer], 'No information was found'
      assert_equal [], result[:citations]
    end
  end

  test 'query injects English prompt when response_locale is :en despite Spanish-looking question' do
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('modernización', response_locale: :en)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, 'You MUST respond entirely in English'
    end
  end

  test 'query does not alter a real answer that happens to start with sorry' do
    real_answer = "Sorry for the delay in this documentation — the procedure is as follows."
    with_mock_bedrock_client(mock_retrieve_and_generate_response: fake_response(real_answer)) do
      service = BedrockRagService.new
      result = service.query('What is the procedure?')

      assert_equal real_answer, result[:answer]
    end
  end

  test 'uses BEDROCK_RAG_* env vars when set' do
    with_env_vars(
      'BEDROCK_RAG_NUMBER_OF_RESULTS' => '12',
      'BEDROCK_RAG_GENERATION_TEMPERATURE' => '0.1'
    ) do
      with_mock_bedrock_client do |client|
        service = BedrockRagService.new
        service.query('Test question')

        params = client.last_retrieve_and_generate_params
        kb_config = params.dig(:retrieve_and_generate_configuration, :knowledge_base_configuration)
        retrieval = kb_config[:retrieval_configuration][:vector_search_configuration]
        gen_inference = kb_config.dig(:generation_configuration, :inference_config, :text_inference_config)

        assert_equal 12, retrieval[:number_of_results]
        assert_equal 0.1, gen_inference[:temperature]
      end
    end
  end

  test 'works with tenant nil (single-tenant)' do
    with_mock_bedrock_client do
      service = BedrockRagService.new(tenant: nil)
      result = service.query('What is S3?')

      assert result.key?(:answer)
      assert result.key?(:citations)
    end
  end

  test 'query appends session_context to generation prompt when provided' do
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      ctx = "## Session Focus\n- [document] manual.pdf"
      service.query('What is S3?', session_context: ctx)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, '## Session Focus'
      assert_includes template, '[document] manual.pdf'
    end
  end

  test 'query does not append session_context when nil' do
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('What is S3?', session_context: nil)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_not_includes template, 'Session Focus'
    end
  end
end
