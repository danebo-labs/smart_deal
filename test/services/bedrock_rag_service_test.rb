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

  # Regression: long accent-less Spanish queries were detected as :es but Haiku
  # still answered in English because the language directive sat in the middle
  # of the prompt while English chunks + English conversation history were the
  # last signals before generation. Directive must now appear at top, middle,
  # AND after session_context (last position = highest recency weight).
  test 'query reinforces Spanish language directive at top, middle, and tail of prompt' do
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
      assert_includes template, 'You MUST respond entirely in Spanish'
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
      assert_includes template, 'web chat interface'
      assert_includes template, '**double asterisk**'
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

  test 'build_complete_optimized_config adds or_all filter when 2+ entity_s3_uris given' do
    service = BedrockRagService.new
    uris = [ 's3://bucket/doc1.pdf', 's3://bucket/doc2.pdf' ]
    config = service.build_complete_optimized_config(entity_s3_uris: uris)

    filter = config.dig(:retrieval_configuration, :vector_search_configuration, :filter)
    assert_not_nil filter
    assert_equal 2, filter[:or_all].size
    assert_equal 's3://bucket/doc1.pdf', filter[:or_all][0][:equals][:value]
  end

  test 'build_complete_optimized_config uses equals filter for single entity_s3_uri' do
    service = BedrockRagService.new
    config = service.build_complete_optimized_config(entity_s3_uris: [ 's3://bucket/only.pdf' ])

    filter = config.dig(:retrieval_configuration, :vector_search_configuration, :filter)
    assert_not_nil filter
    assert_nil filter[:or_all], "Should not use or_all for a single URI"
    assert_equal 's3://bucket/only.pdf', filter.dig(:equals, :value)
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
      assert_equal 's3://bucket/orona_arca_basico.pdf',
                   filter.dig(:equals, :value),
                   "filter must target the explicitly bound source URI"
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

  # --- Token tracking: AnthropicTokenCounter replaces estimate_tokens ---

  test 'query enqueues TrackBedrockQueryJob with AnthropicTokenCounter tokens, not length/4' do
    orig_count_query = AnthropicTokenCounter.method(:count_query)
    AnthropicTokenCounter.define_singleton_method(:count_query) do |**|
      { input_tokens: 5000, output_tokens: 600 }
    end

    with_mock_bedrock_client do
      jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size

      svc = BedrockRagService.new
      svc.query('test question')

      track_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs[jobs_before..].select do |j|
        j[:job] == TrackBedrockQueryJob
      end

      assert_equal 1, track_jobs.size, 'TrackBedrockQueryJob must be enqueued exactly once'
      args = track_jobs.first[:args].first
      assert_equal 5000,    args['input_tokens'],  'input_tokens must come from AnthropicTokenCounter'
      assert_equal 600,     args['output_tokens'], 'output_tokens must come from AnthropicTokenCounter'
      assert_equal 'query', args['source'],        'source must be "query"'
    end
  ensure
    AnthropicTokenCounter.define_singleton_method(:count_query) { |**kwargs| orig_count_query.call(**kwargs) }
  end

  test 'web_delivery_channel_directive includes CITATIONS BEYOND USER SELECTION section' do
    svc = BedrockRagService.allocate
    out = svc.send(:web_delivery_channel_directive)
    assert_match(/CITATIONS BEYOND USER SELECTION/, out)
    assert_match(/Manual Orona 3G/, out)
    assert_match(/extiende lo que ten/, out)
  end
end
