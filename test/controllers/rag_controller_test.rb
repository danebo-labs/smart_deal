# frozen_string_literal: true

require 'test_helper'

class RagControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  TEST_SESSION_ID = 'test-session-123'
  TEST_QUESTION = 'What is S3?'
  TEST_ANSWER = 'This is a test answer about S3'

  setup do
    @user = users(:one)
    # Must match AccountHostResolver for www.example.com (test default host).
    @account = accounts(:legacy)
    @user.update!(account: @account)
  end

  def with_mock_orchestrator(mock_orchestrator)
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_args, **_kwargs| mock_orchestrator }
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  def with_mock_bedrock_rag_service(mock_service)
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*_args, **_kwargs| mock_service }
    yield
  ensure
    BedrockRagService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  def create_mock_orchestrator(answer:, citations: [], session_id: TEST_SESSION_ID,
                               should_raise: false, error_class: StandardError, error_message: nil,
                               documents_uploaded: nil, images_uploaded: nil, doc_refs: nil,
                               correlation_id: nil)
    mock = Object.new
    mock.define_singleton_method(:execute) do
      raise error_class, error_message || 'Service error' if should_raise

      result = {
        answer: answer,
        citations: citations,
        session_id: session_id
      }
      result[:documents_uploaded] = documents_uploaded if documents_uploaded.present?
      result[:images_uploaded]    = images_uploaded    if images_uploaded.present?
      result[:correlation_id]     = correlation_id     if correlation_id.present?
      result[:doc_refs]           = doc_refs            if doc_refs.present?
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

  test 'image upload returns images_uploaded so frontend shows dots-only ack' do
    sign_in @user

    mock = create_mock_orchestrator(
      answer:          I18n.t('rag.image_analyzing_message', locale: :es),
      citations:       [],
      session_id:      nil,
      images_uploaded: [ 'circuit.jpeg' ],
      correlation_id:  'photo:controller-test'
    )

    stub_compression_with_thumbnail do
      with_mock_orchestrator(mock) do
        post rag_ask_url,
             params: {
               question: '',
               image: {
                 data: Base64.strict_encode64('fake-bytes'),
                 media_type: 'image/jpeg',
                 filename: 'circuit.jpeg'
               }
             },
             as: :json
        assert_response :success

        json = json_response
        assert_equal 'success', json['status']
        assert_equal [ 'circuit.jpeg' ], json['images_uploaded'],
                     'images_uploaded must be present so the chat shows only the typing dots until KbSync indexed event'
        assert_equal 'photo:controller-test', json['correlation_id']
      end
    end
  end

  test 'photo question is stored once with attribution and transient analyzing copy is not history' do
    sign_in @user
    mock = create_mock_orchestrator(
      answer: I18n.t('rag.image_analyzing_message', locale: :es),
      citations: [],
      session_id: nil,
      images_uploaded: [ 'panel.jpg' ],
      correlation_id: 'photo:history-test'
    )

    stub_compression_with_thumbnail do
      with_mock_orchestrator(mock) do
        post rag_ask_url,
             params: {
               question: '¿Qué se observa?',
               image: {
                 data: Base64.strict_encode64('fake-bytes'),
                 media_type: 'image/jpeg',
                 filename: 'panel.jpg'
               }
             },
             as: :json
      end
    end

    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: 'web', account: @account)
    assert_equal 1, session.conversation_history.size
    message = session.conversation_history.first
    assert_equal 'user', message['role']
    assert_equal @user.id, message['user_id']
    assert_match(/\Aphoto:/, message['correlation_id'])
  end

  test "text query tracking is attributed to the current account, user, and conversation" do
    sign_in @user
    BedrockQuery.delete_all
    original_new = QueryOrchestratorService.method(:new)

    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      fake = Object.new
      fake.define_singleton_method(:execute) do
        TrackBedrockQueryJob.perform_now(
          model_id: "claude-sonnet-4-6-direct",
          input_tokens: 10,
          output_tokens: 5,
          user_query: "attributed question",
          latency_ms: 20,
          account_id: kwargs.fetch(:account).id,
          user_id: kwargs[:user_id],
          conversation_session_id: kwargs[:conversation_session_id]
        )
        { answer: "Attributed answer", citations: [], session_id: nil }
      end
      fake
    end

    post rag_ask_url, params: { question: "attributed question" }, as: :json

    assert_response :ok
    record = BedrockQuery.last
    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: "web", account: @account)
    assert_equal @account.id, record.account_id
    assert_equal @user.id, record.user_id
    assert_equal session.id, record.conversation_session_id
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) } if original_new
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

  test 'returns successful response with answer and citations when sources are visible' do
    sign_in @user

    citations = [{ filename: 'test.pdf', title: 'Test Document' }]

    mock = create_mock_orchestrator(
      answer: TEST_ANSWER,
      citations: citations,
      session_id: TEST_SESSION_ID
    )

    with_show_rag_sources('true') do
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
  end

  # ─── resolution contract (docs/RAG_RESOLUTION_MODE_CONTRACT_FASE3_2026-07-29.md) ─

  test 'resolution is emitted with mode not_applicable and needs_selection false (no selector yet)' do
    sign_in @user

    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: [])

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      assert_response :success

      resolution = json_response['resolution']
      assert_equal 'resolution_v1', resolution['contract_version']
      assert_equal 'not_applicable', resolution['mode']
      assert_equal false, resolution['needs_selection']
      assert_equal [], resolution['answered_relations']
      assert_equal [], resolution['abstained_relations']
      assert_nil resolution['insufficient_reason']
      assert_equal [], resolution['facts']
      assert_equal [], resolution['evidence_cards']
    end
  end

  test 'resolution needs_selection is always the equality mode == ambiguous' do
    sign_in @user

    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: [])

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json

      resolution = json_response['resolution']
      assert_equal(resolution['mode'] == 'ambiguous', resolution['needs_selection'])
    end
  end

  test 'selector plus card flags expose the resolution contract while preserving the answer path' do
    sign_in @user

    question = '¿A qué serie corresponde el LED SPM?'
    mock = create_mock_orchestrator(answer: 'Respuesta generativa existente.', citations: [])
    rag_service = Object.new
    rag_service.define_singleton_method(:retrieve_chunks) do |*_args, **_kwargs|
      {
        chunks: [
          {
            content: "## HIDRA TPR50\nSPM | SERIE PUERTAS CABINA - EXTERIORES",
            metadata: {
              "section_identity" => "CARLOS SILVA",
              "canonical_name" => "SEGURIDADES 1.1-1",
              "document_id" => "doc-1",
              "page_number" => 9
            },
            location_uri: "s3://bucket/chunk_9.txt",
            chunk_sha256: "chunk-9",
            rank: 1
          }
        ]
      }
    end

    with_evidence_flags(selector: "true", cards: "true") do
      with_mock_orchestrator(mock) do
        with_mock_bedrock_rag_service(rag_service) do
          post rag_ask_url, params: { question: question }, as: :json
        end
      end
    end

    assert_response :success
    json = json_response
    assert_equal 'Respuesta generativa existente.', json['answer']
    assert_equal 'direct', json.dig('resolution', 'mode')
    assert_equal false, json.dig('resolution', 'needs_selection')
    assert_equal 1, json.dig('resolution', 'evidence_cards').size
    assert_nil json.dig('resolution', 'evidence_cards', 0, 'page')
    assert_equal 'SPM', json.dig('resolution', 'facts', 0, 'identifier')
  end

  test "answered and abstained structured turns issue one retrieve with selector and partial contract on or off" do
    sign_in @user
    retrieval_calls = 0
    rag_service = Object.new
    rag_service.define_singleton_method(:retrieve_chunks) do |*_args, **_kwargs|
      retrieval_calls += 1
      { chunks: [], retrieval_trace: {} }
    end

    [
      [ :answered, "Respuesta estructurada." ],
      [ :abstained, I18n.t("rag.data_not_available", locale: :es) ]
    ].each do |outcome, answer|
      orchestrator = Object.new
      orchestrator.define_singleton_method(:execute) do
        rag_service.retrieve_chunks("¿Qué indica el LED ABC12?")
        {
          answer: answer,
          citations: [],
          session_id: nil,
          generation_mode: Rag::StructuredEvidenceRoute::GENERATION_MODE,
          model_invoked: outcome == :answered
        }
      end

      [ "false", "true" ].product([ "false", "true" ]).each do |selector, partial_contract|
        retrieval_calls = 0
        with_partial_abstention_contract(partial_contract) do
          with_evidence_flags(selector: selector, cards: "false") do
            with_mock_orchestrator(orchestrator) do
              with_mock_bedrock_rag_service(rag_service) do
                post rag_ask_url, params: { question: "¿Qué indica el LED ABC12?" }, as: :json
              end
            end
          end
        end

        assert_response :success
        assert_equal 1, retrieval_calls,
          "outcome=#{outcome} selector=#{selector} partial=#{partial_contract} issued more than one Retrieve"
        assert_equal answer, json_response["answer"]
        assert_equal "not_applicable", json_response.dig("resolution", "mode")
      end
    end
  end

  # A fully-answered structured-route response that legitimately cites a
  # per-field "El documento no incluye este dato" caveat (ABSTENTION_PATTERN)
  # must not be misclassified as abstained in interaction_completed — the
  # route's own structural route_outcome must win over the text heuristic.
  test 'interaction_completed reports answered when route_outcome says answered even if the text matches ABSTENTION_PATTERN' do
    sign_in @user

    answer = "Componente conectado: PULSADOR [1]\n\n" \
      "- **APC** — etiqueta visible; función El documento no incluye este dato en este diagrama"
    orchestrator = Object.new
    orchestrator.define_singleton_method(:execute) do
      {
        answer: answer,
        citations: [ { number: 1, filename: 'test.pdf', title: 'Test' } ],
        session_id: nil,
        generation_mode: Rag::StructuredEvidenceRoute::GENERATION_MODE,
        route_outcome: :answered
      }
    end

    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    with_mock_orchestrator(orchestrator) do
      post rag_ask_url, params: { question: '¿Qué conectores tiene el obstáculo?' }, as: :json
    end

    Rails.logger.stop_broadcasting_to(logger)

    assert_response :success
    line = output.string.lines.find { |entry| entry.include?('[PILOT_USAGE]') && entry.include?('"interaction_completed"') }
    assert line.present?, 'interaction_completed must be emitted'
    payload = JSON.parse(line.split('[PILOT_USAGE] ', 2).last)
    assert_equal 'answered', payload['outcome']
  end

  test 'interaction_completed reports abstained when route_outcome says abstained regardless of answer text' do
    sign_in @user

    orchestrator = Object.new
    orchestrator.define_singleton_method(:execute) do
      {
        answer: 'Respuesta sin ninguna palabra clave de abstención.',
        citations: [],
        session_id: nil,
        generation_mode: Rag::StructuredEvidenceRoute::GENERATION_MODE,
        route_outcome: :abstained
      }
    end

    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    with_mock_orchestrator(orchestrator) do
      post rag_ask_url, params: { question: 'pregunta sin evidencia' }, as: :json
    end

    Rails.logger.stop_broadcasting_to(logger)

    line = output.string.lines.find { |entry| entry.include?('[PILOT_USAGE]') && entry.include?('"interaction_completed"') }
    payload = JSON.parse(line.split('[PILOT_USAGE] ', 2).last)
    assert_equal 'abstained', payload['outcome']
  end

  test 'interaction_completed falls back to the text heuristic when the route has no structural route_outcome' do
    sign_in @user

    mock = create_mock_orchestrator(answer: I18n.t('rag.data_not_available', locale: :es))

    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
    end

    Rails.logger.stop_broadcasting_to(logger)

    line = output.string.lines.find { |entry| entry.include?('[PILOT_USAGE]') && entry.include?('"interaction_completed"') }
    payload = JSON.parse(line.split('[PILOT_USAGE] ', 2).last)
    assert_equal 'abstained', payload['outcome']
  end

  # ─── SHOW_RAG_SOURCES transport gate (§3.2/§3.3) ────────────────────────────

  test 'with sources hidden, citations are not transported and content never appears' do
    sign_in @user

    citations = [{ number: 1, filename: 'test.pdf', title: 'Test Document', tooltip_excerpt: 'algo' }]
    mock = create_mock_orchestrator(answer: "#{TEST_ANSWER}[1]", citations: citations)

    with_show_rag_sources('false') do
      with_mock_orchestrator(mock) do
        post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
        assert_response :success

        json = json_response
        assert_equal [], json['citations']
        assert_not @response.body.include?('"content"'), 'the flag-off payload must never carry chunk content'
      end
    end
  end

  test 'no payload ever contains a content key, flag on or off (§3.3 invariant 3)' do
    sign_in @user

    citations = [{ number: 1, filename: 'test.pdf', title: 'Test Document', tooltip_excerpt: 'algo' }]
    mock = create_mock_orchestrator(answer: "#{TEST_ANSWER}[1]", citations: citations)

    [ 'true', 'false' ].each do |flag|
      with_show_rag_sources(flag) do
        with_mock_orchestrator(mock) do
          post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
          assert_not @response.body.include?('"content"'), "flag=#{flag} leaked a content key"
        end
      end
    end
  end

  test 'a bracketed number that does not resolve to a citation survives with sources hidden (§3.3 invariant 4, C2 regression)' do
    sign_in @user

    citations = [{ number: 1, filename: 'test.pdf', title: 'Test Document' }]
    mock = create_mock_orchestrator(
      answer: 'El terminal [24] alimenta la bobina.[1]',
      citations: citations
    )

    with_show_rag_sources('false') do
      with_mock_orchestrator(mock) do
        post rag_ask_url, params: { question: TEST_QUESTION }, as: :json

        json = json_response
        assert_includes json['answer'], '[24]'
        assert_not_includes json['answer'], '[1]'
      end
    end
  end

  test 'resolution.mode, relations, and marker-free answer text match across both flag states (§3.3 invariant 1)' do
    sign_in @user

    citations = [{ number: 1, filename: 'test.pdf', title: 'Test Document' }]

    results = [ 'true', 'false' ].map do |flag|
      mock = create_mock_orchestrator(answer: "#{TEST_ANSWER}[1]", citations: citations)
      with_show_rag_sources(flag) do
        with_mock_orchestrator(mock) do
          post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
          json_response
        end
      end
    end

    on_json, off_json = results
    assert_equal on_json['resolution']['mode'], off_json['resolution']['mode']
    assert_equal on_json['resolution']['answered_relations'], off_json['resolution']['answered_relations']
    assert_equal on_json['resolution']['abstained_relations'], off_json['resolution']['abstained_relations']
    assert_equal on_json['answer'].gsub(/\[\d+\]/, ''), off_json['answer'].gsub(/\[\d+\]/, '')
  end

  # ─── Fallback "Documentos consultados" (doc_refs without inline citations) ─

  test 'includes consulted_documents fallback when citations are empty but doc_refs present' do
    sign_in @user

    doc_refs = [
      { "source_uri" => "s3://bucket/manual.pdf", "canonical_name" => "Manual", "aliases" => [], "doc_type" => "manual" },
      { "source_uri" => "s3://bucket/manual.pdf", "canonical_name" => "Manual", "aliases" => [], "doc_type" => "manual" }
    ]
    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: [], doc_refs: doc_refs)

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      assert_response :success

      json = json_response
      assert_equal [ 'Manual' ], json['consulted_documents'], 'must dedup canonical_name across doc_refs'
    end
  end

  test 'omits consulted_documents on the deterministic_document_overview path (V8, no duplicate attribution)' do
    sign_in @user

    doc_refs = [
      { "source_uri" => "s3://bucket/manual-a.pdf", "canonical_name" => "Manual A" },
      { "source_uri" => "s3://bucket/manual-b.pdf", "canonical_name" => "Manual B" }
    ]

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **_kwargs|
      obj = Object.new
      obj.define_singleton_method(:execute) do
        { answer: "Documento: Manual A\nS1\n\nDocumento: Manual B\nS1", citations: [], doc_refs: doc_refs,
          session_id: nil, generation_mode: "deterministic_document_overview" }
      end
      obj
    end

    begin
      post rag_ask_url, params: { question: "Manual A Manual B" }, as: :json
      assert_response :ok

      json = json_response
      assert_not json.key?("consulted_documents"),
                 "the overview answer already names each document as a heading"
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
    end
  end

  test 'does not include consulted_documents when citations are present' do
    sign_in @user

    citations = [ { filename: 'test.pdf', title: 'Test Document' } ]
    doc_refs  = [ { "source_uri" => "s3://bucket/test.pdf", "canonical_name" => "Test Document" } ]
    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: citations, doc_refs: doc_refs)

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      assert_response :success

      json = json_response
      assert_not json.key?('consulted_documents'), 'must not duplicate sources already shown via citations'
    end
  end

  test 'omits consulted_documents when there are neither citations nor doc_refs' do
    sign_in @user

    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: [])

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      assert_response :success

      json = json_response
      assert_not json.key?('consulted_documents')
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

  # Fase 1 (plan_tracking_piloto_2026-08-04.md, restriction 4): the
  # interaction_completed payload may carry the error CLASS but never the AWS
  # exception message, a backtrace, or any other key outside
  # PilotUsageLog::ALLOWED_FIELDS.
  test 'interaction_completed payload on a failed interaction never carries the error message or backtrace' do
    sign_in @user

    aws_message = 'AccessDeniedException: arn:aws:iam::123456789012:role/secret-role is not authorized'
    mock = create_mock_orchestrator(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::BedrockServiceError,
      error_message: aws_message
    )

    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: 'test question' }, as: :json
    end

    Rails.logger.stop_broadcasting_to(logger)

    line = output.string.lines.find { |entry| entry.include?('[PILOT_USAGE]') && entry.include?('"interaction_completed"') }
    assert line.present?, 'interaction_completed must be emitted on a failed interaction'
    payload = JSON.parse(line.split('[PILOT_USAGE] ', 2).last)

    assert_equal 'failed', payload['outcome']
    assert_equal 'service_error', payload['stage']
    assert_equal 'BedrockRagService::BedrockServiceError', payload['error_class']
    assert_equal 'text', payload['route']
    assert_not_includes line, aws_message
    assert_not payload.key?('message')
    assert_not payload.key?('error_message')
    assert_not payload.key?('backtrace')
    assert_not payload.key?('prompt')
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

    # Mock returns I18n.t which uses the locale set by with_request_locale around_action
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

  test 'returns no_results message in Spanish (app locale fixed to :es)' do
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
      assert_includes json["answer"], "No se encontró información"
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
      user_id:    @user.id,
      account_id: @account.id
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

  test 'ask calls KbDocumentEnrichmentService (no session entity registration from citations)' do
    sign_in @user

    citations = [ { number: 1, filename: 'guide.pdf', title: 'Guide' } ]
    mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: citations)

    with_mock_orchestrator(mock) do
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
    end

    assert_response :success
    # Haiku citations no longer register session entities — only pins do.
    session = ConversationSession.find_by(identifier: @user.id.to_s, channel: 'web')
    assert_empty session.active_entities
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

  # ─── SharedSession ──────────────────────────────────────────────────────────

  test 'with shared session enabled, ask uses shared identifier and stores nil user_id' do
    stub_shared_enabled(true) do
      ConversationSession.where(identifier: SharedSession::IDENTIFIER, channel: SharedSession::CHANNEL).destroy_all
      sign_in @user
      mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: [])

      with_mock_orchestrator(mock) do
        post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      end
      assert_response :success

      session = ConversationSession.find_by(identifier: SharedSession::IDENTIFIER, channel: SharedSession::CHANNEL)
      assert session.present?, 'Shared session must be created'
      assert_nil session.user_id, 'user_id must be nil in shared mode to avoid ownership confusion'
    end
  end

  test 'with shared session enabled, two web requests reuse the same conv_session row' do
    stub_shared_enabled(true) do
      ConversationSession.where(identifier: SharedSession::IDENTIFIER, channel: SharedSession::CHANNEL).destroy_all
      sign_in @user
      mock = create_mock_orchestrator(answer: TEST_ANSWER, citations: [])

      with_mock_orchestrator(mock) do
        assert_difference 'ConversationSession.count', 1 do
          post rag_ask_url, params: { question: 'first question' }, as: :json
        end
        assert_no_difference 'ConversationSession.count' do
          post rag_ask_url, params: { question: 'second question' }, as: :json
        end
      end

      assert_equal 1, ConversationSession.where(identifier: SharedSession::IDENTIFIER, channel: SharedSession::CHANNEL).count
    end
  end

  private

  # Bypasses Vips/libvips so we can test the controller's image upload branch
  # with a fake base64 payload.
  def stub_compression_with_thumbnail
    original = ImageCompressionService.method(:compress_with_thumbnail)
    ImageCompressionService.define_singleton_method(:compress_with_thumbnail) do |base64, media_type, **_kwargs|
      {
        data:                   base64,
        media_type:             media_type,
        binary:                 Base64.decode64(base64),
        thumbnail_binary:       "thumb",
        thumbnail_content_type: "image/jpeg",
        thumbnail_width:        44,
        thumbnail_height:       44
      }
    end
    yield
  ensure
    ImageCompressionService.define_singleton_method(:compress_with_thumbnail) { |*a, **k| original.call(*a, **k) }
  end

  def stub_shared_enabled(enabled)
    orig = SharedSession::ENABLED
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, enabled)
    yield
  ensure
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, orig)
  end

  def with_show_rag_sources(value)
    original = ENV.fetch("SHOW_RAG_SOURCES", nil)
    ENV["SHOW_RAG_SOURCES"] = value
    yield
  ensure
    if original.nil?
      ENV.delete("SHOW_RAG_SOURCES")
    else
      ENV["SHOW_RAG_SOURCES"] = original
    end
  end

  def with_evidence_flags(selector:, cards:)
    original_selector = ENV.fetch("RAG_EVIDENCE_SELECTOR_ENABLED", nil)
    original_cards = ENV.fetch("RAG_EVIDENCE_CARDS_ENABLED", nil)
    ENV["RAG_EVIDENCE_SELECTOR_ENABLED"] = selector
    ENV["RAG_EVIDENCE_CARDS_ENABLED"] = cards
    yield
  ensure
    original_selector.nil? ? ENV.delete("RAG_EVIDENCE_SELECTOR_ENABLED") : ENV["RAG_EVIDENCE_SELECTOR_ENABLED"] = original_selector
    original_cards.nil? ? ENV.delete("RAG_EVIDENCE_CARDS_ENABLED") : ENV["RAG_EVIDENCE_CARDS_ENABLED"] = original_cards
  end

  def with_partial_abstention_contract(value)
    original = ENV.fetch("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil)
    ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = value
    yield
  ensure
    if original.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = original
    end
  end

  test 'ask passes force_entity_filter: true when session has pins' do
    sign_in @user

    kb_doc  = KbDocument.create!(s3_key: "uploads/2026/q.pdf", display_name: "Q", aliases: [])
    session = ConversationSession.find_or_create_for(identifier: @user.id.to_s, channel: "web", account_id: @account.id)
    session.pin_kb_document!(kb_doc)

    captured = {}
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*args, **kwargs|
      captured.merge!(kwargs)
      obj = Object.new
      obj.define_singleton_method(:execute) do
        { answer: "x", citations: [], retrieved_citations: [], doc_refs: nil, session_id: nil }
      end
      obj
    end

    begin
      post rag_ask_url, params: { question: "test" }, as: :json
      assert_response :ok
      assert_equal true, captured[:force_entity_filter]
      assert_includes captured[:entity_s3_uris], kb_doc.display_s3_uri(KbDocument::KB_BUCKET)
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
    end
  end

  test "ask passes field_photo_id through to QueryOrchestratorService" do
    sign_in @user

    captured = {}
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured.merge!(kwargs)
      obj = Object.new
      obj.define_singleton_method(:execute) { { answer: "x", citations: [], session_id: nil } }
      obj
    end

    begin
      post rag_ask_url, params: { question: "what does this show?", field_photo_id: "42" }, as: :json
      assert_response :ok
      assert_equal "42", captured[:field_photo_id]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
    end
  end

  test "ask omits field_photo_id when the param is absent" do
    sign_in @user

    captured = {}
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured.merge!(kwargs)
      obj = Object.new
      obj.define_singleton_method(:execute) { { answer: "x", citations: [], session_id: nil } }
      obj
    end

    begin
      post rag_ask_url, params: { question: TEST_QUESTION }, as: :json
      assert_response :ok
      assert_nil captured[:field_photo_id]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
    end
  end

  # ─── resolve_response_locale: history continuity for ambiguous follow-ups ──

  def with_captured_orchestrator_kwargs
    captured = {}
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured.merge!(kwargs)
      obj = Object.new
      obj.define_singleton_method(:execute) { { answer: "x", citations: [], session_id: nil } }
      obj
    end

    yield captured
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  test "resolve_response_locale continues an English thread on an ambiguous short follow-up" do
    sign_in @user

    session = ConversationSession.find_or_create_for(
      identifier: @user.id.to_s, channel: "web", account_id: @account.id
    )
    session.add_to_history("user", "What is the reset procedure for this panel?")

    with_captured_orchestrator_kwargs do |captured|
      post rag_ask_url, params: { question: "Instalar" }, as: :json
      assert_response :ok
      assert_equal :en, captured[:response_locale]
    end
  end

  test "resolve_response_locale continues a Spanish thread on an ambiguous short follow-up" do
    sign_in @user

    session = ConversationSession.find_or_create_for(
      identifier: @user.id.to_s, channel: "web", account_id: @account.id
    )
    session.add_to_history("user", "¿Cuál es el procedimiento de reinicio de este panel?")

    with_captured_orchestrator_kwargs do |captured|
      post rag_ask_url, params: { question: "Instalar" }, as: :json
      assert_response :ok
      assert_equal :es, captured[:response_locale]
    end
  end

  test "resolve_response_locale defaults to :es for an ambiguous question with no history" do
    sign_in @user

    with_captured_orchestrator_kwargs do |captured|
      post rag_ask_url, params: { question: "Instalar" }, as: :json
      assert_response :ok
      assert_equal :es, captured[:response_locale]
    end
  end

  def json_response
    JSON.parse(@response.body)
  end
end
