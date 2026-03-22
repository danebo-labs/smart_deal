# frozen_string_literal: true

require 'test_helper'

class QueryOrchestratorServiceTest < ActiveSupport::TestCase
  DB_RESPONSE = {
    answer: 'There are 5 customers in the database.',
    citations: [],
    session_id: nil
  }.freeze

  KB_RESPONSE = {
    answer: 'EC2 is a virtual server in the AWS cloud.',
    citations: [ { number: 1, title: 'AWS Docs', filename: 'ec2.pdf' } ],
    session_id: 'kb-session-123'
  }.freeze

  # ============================================
  # Helpers: stub AiProvider for classification
  # ============================================

  # Creates a mock AiProvider that returns a controlled classification response.
  def mock_ai_provider(classification_response, synthesis_response: nil)
    call_count = 0
    provider = Object.new
    provider.define_singleton_method(:query) do |_prompt, **_kwargs|
      call_count += 1
      # First call is classification, subsequent calls are synthesis (hybrid)
      if call_count == 1
        classification_response
      else
        synthesis_response || 'Merged answer from both sources.'
      end
    end
    provider
  end

  # Stubs AiProvider.new to return our mock for the duration of the block.
  def with_mock_ai_provider(mock_provider)
    original_new = AiProvider.method(:new)
    AiProvider.define_singleton_method(:new) { |**_kwargs| mock_provider }
    yield
  ensure
    AiProvider.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) }
  end

  # Stubs SqlGenerationService to return a controlled response.
  def with_mock_sql_service(response: DB_RESPONSE, should_raise: false, error_class: StandardError)
    original_new = SqlGenerationService.method(:new)
    mock_service = Object.new
    mock_service.define_singleton_method(:execute) do
      raise error_class, 'SQL service error' if should_raise
      response
    end
    SqlGenerationService.define_singleton_method(:new) { |*_args, **_kwargs| mock_service }
    yield
  ensure
    SqlGenerationService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  # Stubs BedrockRagService to return a controlled response.
  def with_mock_kb_service(response: KB_RESPONSE, should_raise: false, error_class: StandardError)
    original_new = BedrockRagService.method(:new)
    mock_service = Object.new
    mock_service.define_singleton_method(:query) do |*_args, **_kwargs|
      raise error_class, 'KB service error' if should_raise
      response
    end
    BedrockRagService.define_singleton_method(:new) { |*_args, **_kwargs| mock_service }
    yield
  ensure
    BedrockRagService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  # Combines all three mocks for convenience.
  # Yields a tenant mock with DB access so classification logic is active.
  # Pass tenant: nil explicitly in tests that want to verify rag_only bypass.
  def with_all_mocks(classification:, db_response: DB_RESPONSE, kb_response: KB_RESPONSE,
                     db_should_raise: false, kb_should_raise: false, synthesis_response: nil,
                     tenant: :default)
    resolved_tenant = tenant == :default ? mock_tenant_with_db : tenant
    provider = mock_ai_provider(classification, synthesis_response: synthesis_response)
    with_query_routing(enabled: true) do
      with_mock_ai_provider(provider) do
        with_mock_sql_service(response: db_response, should_raise: db_should_raise) do
          with_mock_kb_service(response: kb_response, should_raise: kb_should_raise) do
            yield resolved_tenant
          end
        end
      end
    end
  end

  # Creates a mock tenant with both data sources — enables classification logic.
  def mock_tenant_with_db
    tenant = Object.new
    tenant.define_singleton_method(:data_sources) { [ "rag", "db" ] }
    tenant.define_singleton_method(:try) { |method_name| public_send(method_name) if respond_to?(method_name) }
    tenant
  end

  # Temporarily overrides QUERY_ROUTING_ENABLED for the duration of the block.
  def with_query_routing(enabled:)
    original = ENV['QUERY_ROUTING_ENABLED']
    ENV['QUERY_ROUTING_ENABLED'] = enabled.to_s
    yield
  ensure
    original.nil? ? ENV.delete('QUERY_ROUTING_ENABLED') : ENV['QUERY_ROUTING_ENABLED'] = original
  end

  # Stubs S3DocumentsService and KbSyncService so document/image upload tests
  # never hit AWS. The background thread spawned by execute will use these mocks.
  def with_mock_upload_services
    mock_s3 = Object.new
    mock_s3.define_singleton_method(:upload_file) { |*_args| 'uploads/test/fake-key' }

    mock_kb_sync = Object.new
    mock_kb_sync.define_singleton_method(:sync!) { |*_args| nil }

    original_s3_new = S3DocumentsService.method(:new)
    original_kb_new = KbSyncService.method(:new)

    S3DocumentsService.define_singleton_method(:new) { |*_args| mock_s3 }
    KbSyncService.define_singleton_method(:new) { |*_args| mock_kb_sync }

    yield
    sleep 0.2 # Allow background thread to complete before restoring stubs
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*args, **kwargs| original_s3_new.call(*args, **kwargs) }
    KbSyncService.define_singleton_method(:new) { |*args, **kwargs| original_kb_new.call(*args, **kwargs) }
  end

  # ============================================
  # Tests: Intent classification and routing
  # ============================================

  test 'routes DATABASE_QUERY to SqlGenerationService' do
    with_all_mocks(classification: 'DATABASE_QUERY') do |tenant|
      result = QueryOrchestratorService.new('How many customers do we have?', tenant: tenant).execute

      assert_equal DB_RESPONSE[:answer], result[:answer]
      assert_equal [], result[:citations]
      assert_nil result[:session_id]
    end
  end

  test 'routes KNOWLEDGE_BASE_QUERY to BedrockRagService' do
    with_all_mocks(classification: 'KNOWLEDGE_BASE_QUERY') do |tenant|
      result = QueryOrchestratorService.new('What is EC2?', tenant: tenant).execute

      assert_equal KB_RESPONSE[:answer], result[:answer]
      assert_equal KB_RESPONSE[:citations], result[:citations]
      assert_equal 'kb-session-123', result[:session_id]
    end
  end

  test 'routes HYBRID_QUERY to both services and merges results' do
    with_all_mocks(
      classification: 'HYBRID_QUERY',
      synthesis_response: 'Combined answer about EC2 from both sources.'
    ) do |tenant|
      result = QueryOrchestratorService.new('What EC2 data do we have and what are its features?', tenant: tenant).execute

      assert_equal 'Combined answer about EC2 from both sources.', result[:answer]
      # Citations come from KB
      assert_equal KB_RESPONSE[:citations], result[:citations]
      assert_equal 'kb-session-123', result[:session_id]
    end
  end

  test 'falls back to KNOWLEDGE_BASE_QUERY when classification is unclear' do
    with_all_mocks(classification: 'I am not sure which tool to use') do |tenant|
      result = QueryOrchestratorService.new('Something ambiguous', tenant: tenant).execute

      assert_equal KB_RESPONSE[:answer], result[:answer]
      assert_equal KB_RESPONSE[:citations], result[:citations]
    end
  end

  # ============================================
  # Tests: Classification extraction robustness
  # ============================================

  test 'extracts DATABASE_QUERY even with extra text' do
    with_all_mocks(classification: 'The correct tool is DATABASE_QUERY for this question.') do |tenant|
      result = QueryOrchestratorService.new('How many orders?', tenant: tenant).execute

      assert_equal DB_RESPONSE[:answer], result[:answer]
    end
  end

  test 'extracts KNOWLEDGE_BASE_QUERY even with extra text' do
    with_all_mocks(classification: 'I would recommend using KNOWLEDGE_BASE_QUERY here.') do |tenant|
      result = QueryOrchestratorService.new('Explain IAM policies', tenant: tenant).execute

      assert_equal KB_RESPONSE[:answer], result[:answer]
    end
  end

  test 'extracts HYBRID_QUERY even with extra text' do
    with_all_mocks(
      classification: 'This requires HYBRID_QUERY since it needs both.',
      synthesis_response: 'Merged.'
    ) do |tenant|
      result = QueryOrchestratorService.new('List EC2 records and explain features', tenant: tenant).execute

      assert_equal 'Merged.', result[:answer]
    end
  end

  test 'HYBRID_QUERY takes priority over DATABASE_QUERY in extraction' do
    # If LLM response contains both "HYBRID_QUERY" and "DATABASE_QUERY",
    # HYBRID should win because we check it first.
    with_all_mocks(
      classification: 'Use HYBRID_QUERY not DATABASE_QUERY',
      synthesis_response: 'Hybrid result.'
    ) do |tenant|
      result = QueryOrchestratorService.new('test', tenant: tenant).execute

      assert_equal 'Hybrid result.', result[:answer]
    end
  end

  # ============================================
  # Tests: HYBRID_QUERY fault tolerance
  # ============================================

  test 'HYBRID returns KB result when DB fails' do
    with_all_mocks(classification: 'HYBRID_QUERY', db_should_raise: true) do |tenant|
      result = QueryOrchestratorService.new('test hybrid with db failure', tenant: tenant).execute

      assert_equal KB_RESPONSE[:answer], result[:answer]
      assert_equal KB_RESPONSE[:citations], result[:citations]
    end
  end

  test 'HYBRID returns DB result when KB fails' do
    with_all_mocks(classification: 'HYBRID_QUERY', kb_should_raise: true) do |tenant|
      result = QueryOrchestratorService.new('test hybrid with kb failure', tenant: tenant).execute

      assert_equal DB_RESPONSE[:answer], result[:answer]
      assert_equal [], result[:citations]
    end
  end

  test 'HYBRID returns empty answer when both sources fail' do
    with_all_mocks(
      classification: 'HYBRID_QUERY',
      db_should_raise: true,
      kb_should_raise: true
    ) do |tenant|
      result = QueryOrchestratorService.new('test hybrid with total failure', tenant: tenant).execute

      # Both failed, so DB result (first checked) has nil answer, KB result also nil.
      # The service returns KB result when DB answer is blank.
      assert_nil result[:answer]
    end
  end

  # ============================================
  # Tests: Response format consistency
  # ============================================

  test 'DATABASE_QUERY response has correct shape' do
    with_all_mocks(classification: 'DATABASE_QUERY') do |tenant|
      result = QueryOrchestratorService.new('count customers', tenant: tenant).execute

      assert result.is_a?(Hash)
      assert result.key?(:answer)
      assert result.key?(:citations)
      assert result.key?(:session_id)
    end
  end

  test 'KNOWLEDGE_BASE_QUERY response has correct shape' do
    with_all_mocks(classification: 'KNOWLEDGE_BASE_QUERY') do |tenant|
      result = QueryOrchestratorService.new('what is S3?', tenant: tenant).execute

      assert result.is_a?(Hash)
      assert result.key?(:answer)
      assert result.key?(:citations)
      assert result.key?(:session_id)
    end
  end

  test 'HYBRID_QUERY response has correct shape' do
    with_all_mocks(
      classification: 'HYBRID_QUERY',
      synthesis_response: 'Merged answer.'
    ) do |tenant|
      result = QueryOrchestratorService.new('hybrid question', tenant: tenant).execute

      assert result.is_a?(Hash)
      assert result.key?(:answer)
      assert result.key?(:citations)
      assert result.key?(:session_id)
    end
  end

  # ============================================
  # Tests: RAG-only bypass (MVP / nil tenant)
  # ============================================

  test 'nil tenant bypasses classification and routes directly to KB' do
    ai_invoked = false
    mock_provider = Object.new
    mock_provider.define_singleton_method(:query) { |*_| ai_invoked = true; 'SHOULD NOT BE CALLED' }

    with_mock_ai_provider(mock_provider) do
      with_mock_kb_service do
        result = QueryOrchestratorService.new('What is the elevator manual?').execute

        assert_not ai_invoked, 'AiProvider (classification) must NOT be called for nil tenant'
        assert_equal KB_RESPONSE[:answer], result[:answer]
      end
    end
  end

  test 'rag-only tenant (data_sources: ["rag"]) bypasses classification' do
    rag_tenant = Object.new
    rag_tenant.define_singleton_method(:data_sources) { [ "rag" ] }
    rag_tenant.define_singleton_method(:try) { |m| respond_to?(m) ? public_send(m) : nil }

    ai_invoked = false
    mock_provider = Object.new
    mock_provider.define_singleton_method(:query) { |*_| ai_invoked = true; 'SHOULD NOT BE CALLED' }

    with_mock_ai_provider(mock_provider) do
      with_mock_kb_service do
        result = QueryOrchestratorService.new('What is the elevator manual?', tenant: rag_tenant).execute

        assert_not ai_invoked, 'AiProvider (classification) must NOT be called for rag-only tenant'
        assert_equal KB_RESPONSE[:answer], result[:answer]
      end
    end
  end

  test 'tenant with db data_sources triggers classification when routing is enabled' do
    ai_invoked = false
    mock_provider = Object.new
    mock_provider.define_singleton_method(:query) { |*_| ai_invoked = true; 'KNOWLEDGE_BASE_QUERY' }

    with_query_routing(enabled: true) do
      with_mock_ai_provider(mock_provider) do
        with_mock_kb_service do
          tenant = mock_tenant_with_db
          QueryOrchestratorService.new('test', tenant: tenant).execute

          assert ai_invoked, 'AiProvider (classification) MUST be called when tenant has db source and routing is on'
        end
      end
    end
  end

  test 'QUERY_ROUTING_ENABLED=false bypasses classification even for DB tenant' do
    ai_invoked = false
    mock_provider = Object.new
    mock_provider.define_singleton_method(:query) { |*_| ai_invoked = true; 'DATABASE_QUERY' }

    with_query_routing(enabled: false) do
      with_mock_ai_provider(mock_provider) do
        with_mock_kb_service do
          tenant = mock_tenant_with_db
          result = QueryOrchestratorService.new('How many customers?', tenant: tenant).execute

          assert_not ai_invoked, 'AiProvider must NOT be called when QUERY_ROUTING_ENABLED=false'
          assert_equal KB_RESPONSE[:answer], result[:answer]
        end
      end
    end
  end

  # ============================================
  # Tests: TOOLS constant
  # ============================================

  test 'TOOLS constant is frozen and has expected keys' do
    assert QueryOrchestratorService::TOOLS.frozen?
    assert_equal 'DATABASE_QUERY', QueryOrchestratorService::TOOLS[:DATABASE_QUERY]
    assert_equal 'KNOWLEDGE_BASE_QUERY', QueryOrchestratorService::TOOLS[:KNOWLEDGE_BASE_QUERY]
    assert_equal 'HYBRID_QUERY', QueryOrchestratorService::TOOLS[:HYBRID_QUERY]
    assert_equal 3, QueryOrchestratorService::TOOLS.size
  end

  # ============================================
  # Tests: Document upload flow
  # ============================================

  test 'documents only with blank question returns upload confirmation' do
    with_mock_upload_services do
      docs = [
        { data: Base64.strict_encode64('test content'), media_type: 'text/plain', filename: 'doc.txt' }
      ]
      result = QueryOrchestratorService.new('', documents: docs).execute

      assert result.is_a?(Hash)
      assert_includes result[:answer], 'document'
      assert_includes result[:answer], 'index'
      assert_equal [], result[:citations]
      assert_nil result[:session_id]
    end
  end

  test 'documents with question triggers upload in background and routes query to KB' do
    with_mock_upload_services do
      with_mock_kb_service do
        docs = [
          { data: Base64.strict_encode64('content'), media_type: 'text/markdown', filename: 'readme.md' }
        ]
        result = QueryOrchestratorService.new('What is in the document?', documents: docs).execute

        assert_equal KB_RESPONSE[:answer], result[:answer]
        assert_equal KB_RESPONSE[:citations], result[:citations]
        assert_not result.key?(:documents_uploaded)
      end
    end
  end

  # ============================================
  # Tests: Image upload flow (never sent to LLM)
  # ============================================

  test 'image with question triggers upload in background and routes query to KB' do
    with_mock_upload_services do
      with_mock_kb_service do
        images = [
          { data: Base64.strict_encode64('fake-png-bytes'), media_type: 'image/png', filename: 'chart.png' }
        ]
        result = QueryOrchestratorService.new('What does this chart show?', images: images).execute

        assert_equal KB_RESPONSE[:answer], result[:answer]
        assert_equal KB_RESPONSE[:citations], result[:citations]
        assert_not result.key?(:images_uploaded)
      end
    end
  end

  test 'image without question returns image indexing message' do
    with_mock_upload_services do
      images = [
        { data: Base64.strict_encode64('fake-jpeg-bytes'), media_type: 'image/jpeg', filename: 'photo.jpg' }
      ]
      result = QueryOrchestratorService.new('', images: images).execute

      assert_equal I18n.t('rag.image_indexing_message'), result[:answer]
      assert_includes result[:images_uploaded], 'photo.jpg'
    end
  end

  test 'image upload response (blank query) includes images_uploaded key with filenames' do
    with_mock_upload_services do
      images = [
        { data: Base64.strict_encode64('a'), media_type: 'image/png', filename: 'first.png' },
        { data: Base64.strict_encode64('b'), media_type: 'image/jpeg', filename: 'second.jpg' }
      ]
      result = QueryOrchestratorService.new('', images: images).execute

      assert result.key?(:images_uploaded)
      assert_includes result[:images_uploaded], 'first.png'
      assert_includes result[:images_uploaded], 'second.jpg'
    end
  end

  test 'image upload response (blank query) does NOT include documents_uploaded key' do
    with_mock_upload_services do
      images = [
        { data: Base64.strict_encode64('fake'), media_type: 'image/png', filename: 'img.png' }
      ]
      result = QueryOrchestratorService.new('', images: images).execute

      assert_not result.key?(:documents_uploaded)
    end
  end

  test 'image upload response (blank query) has correct shape' do
    with_mock_upload_services do
      images = [
        { data: Base64.strict_encode64('fake'), media_type: 'image/png', filename: 'img.png' }
      ]
      result = QueryOrchestratorService.new('', images: images).execute

      assert result.is_a?(Hash)
      assert result.key?(:answer)
      assert result.key?(:citations)
      assert result.key?(:session_id)
      assert result.key?(:images_uploaded)
    end
  end

  test 'image with unnamed file receives generated filename in images_uploaded' do
    with_mock_upload_services do
      images = [
        { data: Base64.strict_encode64('fake'), media_type: 'image/png' }
      ]
      result = QueryOrchestratorService.new('', images: images).execute

      assert_equal 1, result[:images_uploaded].size
      assert_match(/image_1/, result[:images_uploaded].first)
    end
  end

  test 'image path does NOT call AiProvider for classification (nil tenant bypasses classify)' do
    invoked = false
    mock_provider = Object.new
    mock_provider.define_singleton_method(:query) { |*_args, **_kwargs| invoked = true; 'should not be called' }

    images = [
      { data: Base64.strict_encode64('fake'), media_type: 'image/png', filename: 'img.png' }
    ]

    with_mock_ai_provider(mock_provider) do
      with_mock_upload_services do
        with_mock_kb_service do
          QueryOrchestratorService.new('What is this?', images: images).execute
        end
      end
    end

    assert_not invoked, 'AiProvider should NOT be called when tenant is nil (rag_only bypass)'
  end
end
