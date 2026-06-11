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
    attr_accessor :retrieve_and_generate_response, :retrieve_response,
                  :should_raise_error, :error_message
    attr_reader :last_retrieve_and_generate_params, :last_retrieve_params

    def initialize(*)
      @retrieve_and_generate_response = nil
      @should_raise_error = false
      @error_message = nil
      @last_retrieve_and_generate_params = nil
      @last_retrieve_params = nil
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

    def retrieve(params)
      @last_retrieve_params = params
      @retrieve_response || ::OpenStruct.new(retrieval_results: [])
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
      assert_includes template, 'You MUST write your ENTIRE response in English'
    end
  end

  # Regression: long accent-less Spanish queries were detected as :es but Haiku
  # still answered in English because only a middle bullet was injected.
  # Directive now appears at TOP (before # ROLE) and TAIL (after session_context).
  # Middle injection removed (cost_opt 2026-05-22: saves ~30-40 tokens/query).
  test 'query reinforces Spanish language directive at top and tail of prompt' do
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      session_context = "## Recent Conversation\nUser: prior question\nAssistant: prior English answer"
      service.query(
        'si deseo hacer una integracion entre ellos guiame paso a paso',
        session_context: session_context
      )

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, '# RESPONSE LANGUAGE (ABSOLUTE PRIORITY)'
      assert_includes template, 'You MUST write your ENTIRE response in Spanish'
      assert_includes template, '# FINAL LANGUAGE REMINDER'
      idx_header = template.index('# RESPONSE LANGUAGE (ABSOLUTE PRIORITY)')
      idx_role   = template.index('# ROLE')
      idx_ctx    = template.index('## Recent Conversation')
      idx_footer = template.index('# FINAL LANGUAGE REMINDER')
      assert idx_header < idx_role, 'language header must precede # ROLE'
      assert idx_ctx < idx_footer,  'final reminder must come after session_context'
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

        # number_of_results is now controlled by RagRetrievalProfile (no-pin → 8),
        # not by BEDROCK_RAG_NUMBER_OF_RESULTS. Temperature still comes from ENV.
        assert_equal 8, retrieval[:number_of_results]
        assert_equal 0.1, gen_inference[:temperature]
      end
    end
  end

  test 'uses documentary fidelity defaults when RAG env vars are absent' do
    with_env_vars(
      'BEDROCK_RAG_GENERATION_TEMPERATURE' => nil,
      'BEDROCK_RAG_GENERATION_MAX_TOKENS' => nil
    ) do
      service = BedrockRagService.new
      config = service.build_complete_optimized_config
      inference = config.dig(
        :generation_configuration,
        :inference_config,
        :text_inference_config
      )

      assert_equal 0.1, inference[:temperature]
      assert_equal 3000, inference[:max_tokens]
    end
  end

  test 'reranks exhaustive candidates from 15 down to 12 when enabled' do
    with_env_vars('BEDROCK_RERANKER_ENABLED' => 'true') do
      service = BedrockRagService.new
      config = service.build_complete_optimized_config(
        question: "Enumera todas las pruebas de funcionamiento",
        entity_sources: [ "document" ]
      )
      vector = config.dig(:retrieval_configuration, :vector_search_configuration)

      assert_equal 15, vector[:number_of_results]
      assert_equal 12,
                   vector.dig(
                     :reranking_configuration,
                     :bedrock_reranking_configuration,
                     :number_of_reranked_results
                   )
    end
  end

  test 'does not pay for reranking on focused queries' do
    with_env_vars('BEDROCK_RERANKER_ENABLED' => 'true') do
      service = BedrockRagService.new
      config = service.build_complete_optimized_config(
        question: "Como pruebo el freno?",
        entity_sources: [ "document" ]
      )
      vector = config.dig(:retrieval_configuration, :vector_search_configuration)

      assert_equal 3, vector[:number_of_results]
      assert_nil vector[:reranking_configuration]
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
      ctx = "## Session Focus\nThe following documents/images have been referenced\n- [document] manual.pdf"
      service.query('What is S3?', session_context: ctx)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, "## Session Focus\nThe following documents"
      assert_includes template, '[document] manual.pdf'
    end
  end

  test 'query appends DELIVERY CHANNEL block when output_channel is :whatsapp' do
    skip "WA channel disabled for MVP — whatsapp_delivery_channel_directive removed"
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('What is S3?', output_channel: :whatsapp)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, '# DELIVERY CHANNEL'
      assert_includes template, 'sent via WhatsApp'
      assert_includes template, '① ② ③'
    end
  end

  test 'DELIVERY CHANNEL block prohibits double-asterisk bold' do
    skip "WA channel disabled for MVP — whatsapp_delivery_channel_directive removed"
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('test', output_channel: :whatsapp)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, 'NEVER use **double asterisk**'
    end
  end

  test 'DELIVERY CHANNEL block declares safety warnings as NON-NEGOTIABLE' do
    skip "WA channel disabled for MVP — whatsapp_delivery_channel_directive removed"
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('test', output_channel: :whatsapp)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, 'NON-NEGOTIABLE'
      assert_includes template, 'REQUIRES_FIELD_VERIFICATION'
      assert_includes template, 'VOLTAJE NO VERIFICADO'
    end
  end

  test 'DELIVERY CHANNEL block enumerates intent tokens for faceted output' do
    skip "WA channel disabled for MVP — whatsapp_delivery_channel_directive removed"
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('test', output_channel: :whatsapp)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, 'OUTPUT STRUCTURE'
      assert_includes template, 'IDENTIFICATION'
      assert_includes template, 'TROUBLESHOOTING'
      assert_includes template, 'EMERGENCY'
      assert_includes template, 'EMERGENCY OVERRIDE'
    end
  end

  test 'DELIVERY CHANNEL block defines structured labels and dynamic menu kinds' do
    skip "WA channel disabled for MVP — whatsapp_delivery_channel_directive removed"
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('test', output_channel: :whatsapp)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      %w[[INTENT] [DOCS] [RESUMEN] [RIESGOS] [SECCIONES] [MENU]].each do |label|
        assert_includes template, label, "expected prompt to document label #{label}"
      end
      %w[__riesgos__ __sec_1__ __new_query__].each do |kind|
        assert_includes template, kind, "expected prompt to list menu kind #{kind}"
      end

      # Legacy facet labels must be gone (they leaked multi-doc queries into a
      # single-document frame before the refactor).
      assert_not_includes template, '[PARÁMETROS]'
      assert_not_includes template, '[DETALLE]'

      # Pinned risk-section safety contract must be explicit.
      assert_includes template, 'PINNED'
      assert_includes template, 'sin riesgos específicos documentados'
    end
  end

  test 'web channel appends its own DELIVERY CHANNEL block with web-specific rules' do
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('What is S3?', output_channel: :web)

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, '# DELIVERY CHANNEL'
      assert_includes template, 'technician using web chat'
      assert_includes template, 'under 300 words'
      assert_not_includes template, 'sent via WhatsApp'
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
      # RULE 9 in the base prompt contains the quoted text "## Session Focus" but not
      # the injected block header followed by its descriptive line. That combination
      # only appears when SessionContextBuilder.build injects real session content.
      assert_not_includes template, "## Session Focus\nThe following documents"
    end
  end

  # ============================================
  # 3.1 — Entity-Aware Retrieval Filter
  # ============================================

  test 'build_complete_optimized_config adds or_all filter spanning legacy and batch metadata keys for 2+ entity_s3_uris' do
    service = BedrockRagService.new
    uris = [ 's3://bucket/doc1.pdf', 's3://bucket/doc2.pdf' ]
    config = service.build_complete_optimized_config(entity_s3_uris: uris)

    filter = config.dig(:retrieval_configuration, :vector_search_configuration, :filter)
    assert_not_nil filter
    # Each URI is OR-ed against BOTH x-amz-bedrock-kb-source-uri (legacy) and
    # original_source_uri (batch sidecar) → 2 URIs × 2 keys = 4 clauses.
    assert_equal 4, filter[:or_all].size

    keys_for_doc1 = filter[:or_all]
                      .select { |c| c[:equals][:value] == 's3://bucket/doc1.pdf' }
                      .map { |c| c[:equals][:key] }
    assert_equal %w[x-amz-bedrock-kb-source-uri original_source_uri].sort, keys_for_doc1.sort
  end

  test 'build_complete_optimized_config uses or_all even for a single entity_s3_uri so batch chunks are matched' do
    service = BedrockRagService.new
    config = service.build_complete_optimized_config(entity_s3_uris: [ 's3://bucket/only.pdf' ])

    filter = config.dig(:retrieval_configuration, :vector_search_configuration, :filter)
    assert_not_nil filter
    # Single URI must still OR across both keys (legacy + batch); orAll requires >= 2 members.
    assert_equal 2, filter[:or_all].size
    assert filter[:or_all].all? { |c| c[:equals][:value] == 's3://bucket/only.pdf' }
    assert_equal %w[x-amz-bedrock-kb-source-uri original_source_uri].sort,
                 filter[:or_all].map { |c| c[:equals][:key] }.sort
  end

  test 'build_complete_optimized_config omits filter when entity_s3_uris empty' do
    service = BedrockRagService.new
    config = service.build_complete_optimized_config(entity_s3_uris: [])

    filter = config.dig(:retrieval_configuration, :vector_search_configuration, :filter)
    assert_nil filter
  end

  test 'query sends filter params to Bedrock when entity_s3_uris provided and query is short' do
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('dame los torques', entity_s3_uris: [ 's3://bucket/junction_box.pdf' ])

      filter = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :retrieval_configuration,
        :vector_search_configuration,
        :filter
      )
      assert_not_nil filter, "Expected filter to be present for short query"
    end
  end

  test 'query omits filter when query is long and names a different document' do
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('Show me information about the MotorController installation manual please',
                    entity_s3_uris: [ 's3://bucket/junction_box.pdf' ])

      filter = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :retrieval_configuration,
        :vector_search_configuration,
        :filter
      )
      assert_nil filter, "Expected filter to be absent when query names a different document"
    end
  end

  test 'query omits filter when short query explicitly names a document not in session URIs' do
    # Regression: "Que es el Esquema SOPREL?" (short, 25 chars) was incorrectly filtered
    # to the session document (Orona CPU board), returning wrong results.
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('Que es el Esquema SOPREL?',
                    entity_s3_uris: [ 's3://bucket/Orona CPU board.pdf' ])

      filter = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :retrieval_configuration,
        :vector_search_configuration,
        :filter
      )
      assert_nil filter, "Expected no filter: SOPREL is not in the session URIs even though query is short"
    end
  end

  test 'query applies entity filter when force_entity_filter is true even if query names a different document' do
    # Regression: WhatsApp post-reset doc picker seeds queries like
    # "Describe Orona ARCA BASICO ..." that contain many capitalized words.
    # Without force_entity_filter, query_names_different_document? would
    # bypass the filter and Bedrock would search the whole KB.
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query(
        'Describe Orona ARCA BASICO Safety Circuit Electrical Schematic',
        entity_s3_uris:      [ 's3://bucket/orona_arca_basico.pdf' ],
        force_entity_filter: true
      )

      filter = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :retrieval_configuration,
        :vector_search_configuration,
        :filter
      )
      assert_not_nil filter, "force_entity_filter must scope retrieval to the picked doc"
      values = filter[:or_all].map { |c| c[:equals][:value] }.uniq
      assert_equal [ 's3://bucket/orona_arca_basico.pdf' ], values,
                   "filter must target the explicitly bound source URI on every clause"
      keys = filter[:or_all].map { |c| c[:equals][:key] }.sort
      assert_equal %w[original_source_uri x-amz-bedrock-kb-source-uri], keys
    end
  end

  test 'query appends photo label safety override for photo-only pins' do
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query(
        'Que componentes aparecen?',
        entity_s3_uris: [ 's3://bucket/photo.jpg' ],
        entity_sources: [ 'image_upload' ],
        output_channel: :web,
        force_entity_filter: true
      )

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, "PHOTO LABEL SAFETY OVERRIDE"
      assert_includes template, "Do not group labels under inferred categories"
      assert_includes template, "Safe form: `<LABEL>: identificador visible"
      assert template.index("# DELIVERY CHANNEL") < template.index("PHOTO LABEL SAFETY OVERRIDE")
    end
  end

  test 'query appends stop-work evidence override only for stop-work intent' do
    with_mock_bedrock_client do |client|
      service = BedrockRagService.new
      service.query('Cuando debo detener el trabajo?')

      template = client.last_retrieve_and_generate_params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :generation_configuration,
        :prompt_template,
        :text_prompt_template
      )
      assert_includes template, "STOP-WORK EVIDENCE OVERRIDE"
      assert_includes template, "Precauciones e inspecciones"
      assert_includes template, "Detención obligatoria con evidencia explícita"
      assert_match(/Prior conversation context never promotes a precaution/, template)
    end
  end

  test 'query retries without filter when filtered result returns no results' do
    call_count = 0
    no_results_text = "I'm sorry, I couldn't find relevant information."
    real_answer     = "Here are the torque values: 10 Nm."

    with_mock_bedrock_client do |client|
      client.define_singleton_method(:retrieve_and_generate) do |params|
        call_count += 1
        filter_present = params.dig(
          :retrieve_and_generate_configuration,
          :knowledge_base_configuration,
          :retrieval_configuration,
          :vector_search_configuration,
          :filter
        ).present?
        text = filter_present ? no_results_text : real_answer
        ::OpenStruct.new(output: ::OpenStruct.new(text: text), citations: [], session_id: 'sid')
      end

      service = BedrockRagService.new
      result = service.query('dame los torques', entity_s3_uris: [ 's3://bucket/junction_box.pdf' ])

      assert_equal 2, call_count, "Expected 2 calls: one with filter, one without"
      assert_equal real_answer, result[:answer]
    end
  end

  test 'forced pinned query never retries globally when filtered result has no evidence' do
    call_count = 0
    no_results_text = "I'm sorry, I couldn't find relevant information."

    with_mock_bedrock_client do |client|
      client.define_singleton_method(:retrieve_and_generate) do |_params|
        call_count += 1
        ::OpenStruct.new(
          output: ::OpenStruct.new(text: no_results_text),
          citations: [],
          session_id: "sid"
        )
      end

      service = BedrockRagService.new
      result = service.query(
        "dame el procedimiento inexistente",
        entity_s3_uris: [ "s3://bucket/manual.pdf" ],
        force_entity_filter: true,
        response_locale: :es
      )

      assert_equal 1, call_count
      assert_includes result[:answer], "DATA_NOT_AVAILABLE"
      assert_includes result[:answer], "documentos pineados"
    end
  end

  # ===== detect_language_from_question =====
  # Heuristic must survive accent-less Spanish typed in the field (gloves, mobile keyboards).

  test 'detect_language_from_question: accent/ñ/inverted punctuation → :es' do
    assert_equal :es, BedrockRagService.detect_language_from_question('¿Cuánto tarda?')
    assert_equal :es, BedrockRagService.detect_language_from_question('modernización')
    assert_equal :es, BedrockRagService.detect_language_from_question('año')
  end

  test 'detect_language_from_question: long accent-less Spanish query → :es (regression)' do
    # Real user query that was previously misclassified as English because:
    # - no diacritics
    # - "cuanto" without tilde not in old keyword list
    # - length (94) exceeded the old 80-char cutoff for short-verb heuristic
    q = 'si deseo hacer una integracoon entre ellos guiame paso a paso y cuanto tiempo puede tardar ?'
    assert_equal :es, BedrockRagService.detect_language_from_question(q)
  end

  test 'detect_language_from_question: short accent-less Spanish → :es when >=2 tokens' do
    assert_equal :es, BedrockRagService.detect_language_from_question('dame los torques')
    assert_equal :es, BedrockRagService.detect_language_from_question('como instalar esto')
    assert_equal :es, BedrockRagService.detect_language_from_question('cuanto tiempo tarda')
  end

  test 'detect_language_from_question: English queries → :en' do
    assert_equal :en, BedrockRagService.detect_language_from_question('How do I install this?')
    assert_equal :en, BedrockRagService.detect_language_from_question('What is the torque specification for the brake?')
    assert_equal :en, BedrockRagService.detect_language_from_question('Show me the maintenance procedure')
  end

  test 'detect_language_from_question: single-hit Spanish word in English context stays :en' do
    # "entre" and "sobre" exist as loan-words in English; a single match must not flip locale.
    assert_equal :en, BedrockRagService.detect_language_from_question('tell me about entre nous philosophy')
  end

  test 'detect_language_from_question: blank falls back to I18n.locale' do
    I18n.with_locale(:es) do
      assert_equal :es, BedrockRagService.detect_language_from_question('')
      assert_equal :es, BedrockRagService.detect_language_from_question(nil)
    end
  end

  # --- Token tracking: counting deferred to TrackBedrockQueryJob ---

  test 'query enqueues TrackBedrockQueryJob with raw prompt/answer text (counting deferred)' do
    with_mock_bedrock_client do
      jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size

      svc = BedrockRagService.new
      svc.query('test question')

      track_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs[jobs_before..].select do |j|
        j[:job] == TrackBedrockQueryJob
      end

      assert_equal 1, track_jobs.size, 'TrackBedrockQueryJob must be enqueued exactly once'
      args = track_jobs.first[:args].first
      assert_nil   args['input_tokens'],       'input_tokens must NOT be precomputed in the RAG path'
      assert_nil   args['output_tokens'],      'output_tokens must NOT be precomputed in the RAG path'
      assert_kind_of String, args['prompt_text'], 'prompt_text must be passed for deferred counting'
      assert_kind_of String, args['answer_text'], 'answer_text must be passed for deferred counting'
      assert_kind_of String, args['visible_answer_text'], 'visible answer must be tracked separately'
      assert_equal 'haiku', args['model_for_counting']
      assert_equal 'query', args['source'],         'source must be "query"'
      assert_equal 'prompt_template_plus_observed_chunks',
                   args.dig('regression_context', 'input_token_basis')
      assert_equal 'bedrock_citations',
                   args.dig('regression_context', 'observed_chunk_basis')
    end
  end

  test 'query tracks raw DOC_REFS output while returning a clean visible answer' do
    raw_answer = <<~ANSWER.strip
      The documented value is 13.
      <DOC_REFS>[{"source_uri":"s3://bucket/manual.pdf","canonical_name":"Manual","aliases":[],"doc_type":"manual"}]</DOC_REFS>
    ANSWER
    citation = ::OpenStruct.new(
      retrieved_references: [
        ::OpenStruct.new(
          content: ::OpenStruct.new(text: "Documented value: 13"),
          location: ::OpenStruct.new(
            s3_location: ::OpenStruct.new(uri: "s3://bucket/chunks/manual-1.txt")
          ),
          metadata: {
            "canonical_name" => "Manual",
            "doc_sha256" => "sha-manual",
            "ingestion_path" => "manual_batch_v1",
            "original_source_uri" => "s3://bucket/manual.pdf"
          }
        )
      ]
    )
    response = ::OpenStruct.new(
      output: ::OpenStruct.new(text: raw_answer),
      citations: [ citation ],
      session_id: TEST_SESSION_ID
    )

    with_mock_bedrock_client(mock_retrieve_and_generate_response: response) do
      jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
      result = BedrockRagService.new.query("What is the documented value?")
      job = ActiveJob::Base.queue_adapter.enqueued_jobs[jobs_before..].find do |candidate|
        candidate[:job] == TrackBedrockQueryJob
      end
      args = job[:args].first

      assert_equal "The documented value is 13.[1]", result[:answer]
      assert_equal raw_answer, args["answer_text"]
      assert_equal result[:answer], args["visible_answer_text"]
      assert_equal true, args.dig("regression_context", "doc_refs_present")
      assert_equal true, args.dig("regression_context", "doc_refs_valid")
      assert_equal "sha-manual",
                   args.dig("regression_context", "observed_chunks", 0, "doc_sha256")
      assert_equal "manual_batch_v1",
                   args.dig("regression_context", "observed_chunks", 0, "ingestion_path")
    end
  end

  test 'query does NOT call AnthropicTokenCounter inline (counting deferred to job)' do
    called = false
    orig = AnthropicTokenCounter.method(:count_query)
    AnthropicTokenCounter.define_singleton_method(:count_query) do |**kwargs|
      called = true
      orig.call(**kwargs)
    end

    with_mock_bedrock_client do
      svc = BedrockRagService.new
      svc.query('test question')
    end

    assert_not called, 'BedrockRagService must NOT count tokens during the request'
  ensure
    AnthropicTokenCounter.define_singleton_method(:count_query) { |**kwargs| orig.call(**kwargs) }
  end

  test 'web_delivery_channel_directive favors concise field answers' do
    svc = BedrockRagService.allocate
    out = svc.send(:web_delivery_channel_directive)
    assert_match(/under 300 words/, out)
    assert_match(/Do not repeat the conclusion/, out)
    assert_match(/preserve every retrieved fact/, out)
  end

  test 'exhaustive queries override the web answer length target' do
    svc = BedrockRagService.allocate
    out = svc.send(
      :load_generation_prompt_with_locale,
      'Enumera todas las pruebas de funcionamiento antes de operar',
      response_locale: :es,
      output_channel: :web
    )

    assert_includes out, '# EXHAUSTIVE COMPLETENESS OVERRIDE'
    assert_match(/the 300-word target\s+does not apply/, out)
    assert_match(/final entry count must equal the ledger count/, out)
    assert_match(/Associate each result only with the numbered action/, out)
    assert_match(/keep left\/right, forward\/reverse/, out)
    assert_match(/ground\/platform controls as\s+separate entries/, out)
    assert_match(/Begin immediately with the first\s+`Prueba:` line/, out)
    assert_includes out, 'Do not name or invent a counterpart'
    assert_not_includes out, '# DELIVERY CHANNEL'
    assert out.index('# FINAL LANGUAGE REMINDER') < out.index('# EXHAUSTIVE COMPLETENESS OVERRIDE')
  end

  test 'focused queries do not receive the exhaustive completeness override' do
    svc = BedrockRagService.allocate
    out = svc.send(
      :load_generation_prompt_with_locale,
      '¿Cómo pruebo el freno?',
      response_locale: :es,
      output_channel: :web
    )

    assert_not_includes out, '# EXHAUSTIVE COMPLETENESS OVERRIDE'
  end

  test 'query returns the resolved scope and filter actually applied' do
    with_mock_bedrock_client do
      result = BedrockRagService.new.query(
        '¿Cómo pruebo el freno?',
        entity_s3_uris: [ 's3://bucket/manual.pdf' ],
        entity_sources: [ 'document' ],
        force_entity_filter: true
      )
      trace = result[:retrieval_trace]

      assert_equal [ 's3://bucket/manual.pdf' ], trace[:resolved_scope_s3_uris]
      assert_equal [ 's3://bucket/manual.pdf' ], trace[:applied_filter_s3_uris]
      assert_equal true, trace[:force_entity_filter]
      assert_equal 3, trace.dig(:vector_search_configuration, 'number_of_results')
      assert_match(/\A[0-9a-f]{64}\z/, trace[:vector_search_configuration_sha256])
    end
  end

  test 'retrieve preflight shares the production vector configuration builder' do
    with_mock_bedrock_client do |client|
      client.retrieve_response = ::OpenStruct.new(
        retrieval_results: [
          ::OpenStruct.new(
            content: ::OpenStruct.new(text: 'Prueba documentada'),
            score: 0.9,
            metadata: { 'original_source_uri' => 's3://bucket/manual.pdf' },
            location: ::OpenStruct.new(
              s3_location: ::OpenStruct.new(uri: 's3://bucket/chunks/manual-1.txt')
            )
          )
        ]
      )
      service = BedrockRagService.new
      result = service.retrieve_chunks(
        'Enumera todas las pruebas de funcionamiento',
        entity_s3_uris: [ 's3://bucket/manual.pdf' ],
        entity_sources: [ 'document' ],
        force_entity_filter: true,
        number_of_results: 15
      )
      applied = client.last_retrieve_params.dig(
        :retrieval_configuration,
        :vector_search_configuration
      )
      production = service.build_vector_search_configuration(
        question: 'Enumera todas las pruebas de funcionamiento',
        entity_s3_uris: [ 's3://bucket/manual.pdf' ],
        entity_sources: [ 'document' ],
        number_of_results: 15
      )

      assert_equal production, applied
      assert_equal applied.deep_stringify_keys,
                   result.dig(:retrieval_trace, :vector_search_configuration)
      assert_equal Digest::SHA256.hexdigest('Prueba documentada'),
                   result.dig(:chunks, 0, :chunk_sha256)
    end
  end
end
