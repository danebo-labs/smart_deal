# frozen_string_literal: true

require 'test_helper'

class RagQueryConcernTest < ActiveSupport::TestCase
  # Create a test class that includes the concern
  class TestController
    include RagQueryConcern

    # Mock render method for testing render_rag_json_error
    attr_reader :rendered_json, :rendered_status

    def render(json:, status:)
      @rendered_json = json
      @rendered_status = status
    end
  end

  setup do
    @controller = TestController.new
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
  end

  # Helper method to stub QueryOrchestratorService.new at the class level.
  # The concern now routes through the orchestrator, not BedrockRagService directly.
  def with_mock_orchestrator(mock_orchestrator)
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_args, **_kwargs| mock_orchestrator }
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  # Helper to create a mock QueryOrchestratorService.
  # The orchestrator exposes a single #execute method that returns { answer:, citations:, session_id: }.
  def create_mock_orchestrator(answer:, citations: [], session_id: 'test-session',
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

  # ============================================
  # Tests for execute_rag_query
  # ============================================

  test 'whatsapp short follow-up keeps cached locale' do
    to = 'whatsapp:+15550001111'
    cache_key = "rag_whatsapp_conv/v1/#{to}"
    Rails.cache.write(cache_key, "en", expires_in: 7.days)

    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "Answer", citations: [], session_id: "new-sid" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    begin
      @controller.send(:execute_rag_query, "modernización", whatsapp_to: to)

      assert_nil captured[:kwargs][:session_id]
      assert_equal :en, captured[:kwargs][:response_locale]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'whatsapp first message uses locale detected from body only' do
    to = 'whatsapp:+15550002222'
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "Answer", citations: [], session_id: "s1" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    begin
      @controller.send(:execute_rag_query, "modernización", whatsapp_to: to)

      assert_nil captured[:kwargs][:session_id]
      assert_equal :es, captured[:kwargs][:response_locale]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query returns success result with valid question' do
    mock = create_mock_orchestrator(
      answer: 'Test answer',
      citations: [ 'doc1.pdf' ],
      session_id: 'session-123'
    )

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'What is S3?')

      assert result.success?
      assert_equal 'Test answer', result.answer
      assert_equal [ 'doc1.pdf' ], result.citations
      assert_equal 'session-123', result.session_id
      assert_nil result.error_type
      assert_nil result.faceted, 'web channel should not build a faceted answer'
    end
  end

  test 'execute_rag_query parses faceted answer for whatsapp channel' do
    faceted_raw = <<~ANS
      [INTENT] IDENTIFICATION
      [RESUMEN]
      Orona PCB Mainboard — placa de control del ascensor.
      [RIESGOS]
      (—)
      [PARÁMETROS]
      ① 24VDC
      [SECCIONES]
      - Diagnóstico
      [DETALLE]
      Detalle técnico.
      [MENU]
      1 | Riesgos | riesgos
      2 | Parámetros | parametros
    ANS
    mock = create_mock_orchestrator(answer: faceted_raw, citations: [], session_id: 'sess-1')

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'Que es la PCB?', whatsapp_to: 'whatsapp:+1234')

      assert result.success?
      assert_not_nil result.faceted
      assert_equal :identification, result.faceted.intent
      assert_match(/Orona PCB Mainboard/, result.faceted.facets[:resumen])
      assert result.faceted.facet_empty?(:riesgos)
      assert_equal 2, result.faceted.menu.size
    end
  end

  test 'execute_rag_query faceted falls back to :detalle when labels missing' do
    mock = create_mock_orchestrator(answer: 'Legacy plain answer with no labels.', citations: [], session_id: 's')

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'Hola', whatsapp_to: 'whatsapp:+999')

      assert_not_nil result.faceted
      assert result.faceted.legacy?
      assert_equal 'Legacy plain answer with no labels.', result.faceted.facets[:detalle]
    end
  end

  test 'execute_rag_query returns error for blank question' do
    result = @controller.send(:execute_rag_query, '')

    assert_not result.success?
    assert_equal :blank_question, result.error_type
    assert_nil result.answer
  end

  test 'execute_rag_query returns error for nil question' do
    result = @controller.send(:execute_rag_query, nil)

    assert_not result.success?
    assert_equal :blank_question, result.error_type
  end

  test 'execute_rag_query returns error for whitespace-only question' do
    result = @controller.send(:execute_rag_query, '   ')

    assert_not result.success?
    assert_equal :blank_question, result.error_type
  end

  test 'execute_rag_query handles MissingKnowledgeBaseError' do
    mock = create_mock_orchestrator(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::MissingKnowledgeBaseError,
      error_message: 'KB not configured'
    )

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'test question')

      assert_not result.success?
      assert_equal :config_error, result.error_type
      assert_equal 'KB not configured', result.error_message
    end
  end

  test 'execute_rag_query handles BedrockServiceError' do
    mock = create_mock_orchestrator(
      answer: '',
      should_raise: true,
      error_class: BedrockRagService::BedrockServiceError,
      error_message: 'AWS error'
    )

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'test question')

      assert_not result.success?
      assert_equal :service_error, result.error_type
      assert_equal 'AWS error', result.error_message
    end
  end

  test 'execute_rag_query handles SqlExecutionError' do
    mock = create_mock_orchestrator(
      answer: '',
      should_raise: true,
      error_class: SqlGenerationService::SqlExecutionError,
      error_message: 'SQL execution failed'
    )

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'test question')

      assert_not result.success?
      assert_equal :service_error, result.error_type
      assert_equal 'SQL execution failed', result.error_message
    end
  end

  # ============================================
  # Catalog-level pre-resolution (KbDocumentResolver integration)
  # ============================================

  test 'execute_rag_query injects resolver URIs and context into the orchestrator' do
    KbDocument.delete_all
    KbDocument.create!(
      s3_key:       "uploads/2026-04-10/Esquema SOPREL.pdf",
      display_name: "Esquema SOPREL",
      aliases:      [ "Foremcaro 6118/81" ]
    )

    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    begin
      @controller.send(:execute_rag_query, "que es el Esquema SOPREL?", session_context: "prior ctx")

      assert_includes captured[:kwargs][:entity_s3_uris].join(" "), "Esquema SOPREL.pdf"
      assert_includes captured[:kwargs][:session_context], "Query Resolution"
      assert_includes captured[:kwargs][:session_context], "Esquema SOPREL"
      assert_includes captured[:kwargs][:session_context], "prior ctx"
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query is a no-op on resolver when no catalog match' do
    KbDocument.delete_all

    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    begin
      @controller.send(:execute_rag_query, "query with no catalog hits", session_context: "prior")

      assert_equal [], captured[:kwargs][:entity_s3_uris]
      assert_equal "prior", captured[:kwargs][:session_context]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query handles StandardError' do
    mock = create_mock_orchestrator(
      answer: '',
      should_raise: true,
      error_class: StandardError,
      error_message: 'Unexpected error'
    )

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'test question')

      assert_not result.success?
      assert_equal :unexpected_error, result.error_type
      assert_equal 'Unexpected error', result.error_message
    end
  end

  # ============================================
  # Tests for format_rag_response_for_whatsapp
  # ============================================

  test 'format_rag_response_for_whatsapp returns answer for success' do
    result = RagQueryConcern::RagResult.new(
      success?: true,
      answer: 'This is the answer',
      citations: []
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_equal 'This is the answer', formatted
  end

  test 'format_rag_response_for_whatsapp includes header + sources footer with citations' do
    result = RagQueryConcern::RagResult.new(
      success?: true,
      answer: 'Esta es la respuesta',
      citations: [
        { number: 1, filename: 'doc1.pdf', title: 'Doc 1' },
        { number: 2, filename: 'doc2.pdf', title: 'Doc 2' }
      ]
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    # Opening header (bold, circled numerals) — in Spanish to match answer locale
    assert_includes formatted, '📄 *Documentos consultados:*'
    assert_includes formatted, '① doc1.pdf'
    assert_includes formatted, '② doc2.pdf'

    # Answer body sandwiched between header and footer
    assert_includes formatted, 'Esta es la respuesta'

    # Sources footer — localized
    assert_includes formatted, 'Fuentes:'
    assert_includes formatted, '[1] doc1.pdf'
    assert_includes formatted, '[2] doc2.pdf'

    # Structural order: header → body → footer
    header_idx = formatted.index('Documentos consultados')
    body_idx   = formatted.index('Esta es la respuesta')
    footer_idx = formatted.index('Fuentes:')
    assert header_idx < body_idx && body_idx < footer_idx,
           "Expected header → body → footer order, got #{[ header_idx, body_idx, footer_idx ].inspect}"
  end

  test 'format_rag_response_for_whatsapp uses English labels when answer is in English' do
    result = RagQueryConcern::RagResult.new(
      success?: true,
      answer: 'This is the answer to your question.',
      citations: [ { number: 1, filename: 'manual.pdf', title: 'Manual' } ]
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, '📄 *Documents consulted:*'
    assert_includes formatted, 'Sources:'
  end

  test 'format_rag_response_for_whatsapp deduplicates repeated filenames in header' do
    result = RagQueryConcern::RagResult.new(
      success?: true,
      answer: 'Respuesta con dos citas al mismo doc.',
      citations: [
        { number: 1, filename: 'same.pdf', title: 'Same' },
        { number: 2, filename: 'same.pdf', title: 'Same' }
      ]
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_equal 1, formatted.scan(/① same\.pdf/).size,
                 "Header should list 'same.pdf' once with ①"
    assert_not_includes formatted, '② same.pdf'

    # Footer keeps both [n] entries (for inline cross-reference)
    assert_includes formatted, '[1] same.pdf'
    assert_includes formatted, '[2] same.pdf'
  end

  test 'format_rag_response_for_whatsapp returns fallback for empty answer' do
    result = RagQueryConcern::RagResult.new(
      success?: true,
      answer: '',
      citations: []
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_equal "I couldn't find an answer.", formatted
  end

  test 'format_rag_response_for_whatsapp returns error message for blank_question' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :blank_question
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, 'Please send a question'
  end

  test 'format_rag_response_for_whatsapp returns error message for config_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :config_error
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, 'not properly configured'
  end

  test 'format_rag_response_for_whatsapp returns error message for service_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :service_error
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, 'Error querying knowledge base'
    assert_includes formatted, 'Please try again later'
  end

  test 'format_rag_response_for_whatsapp returns error message for unexpected_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :unexpected_error,
      error_message: 'Something went wrong'
    )

    formatted = @controller.send(:format_rag_response_for_whatsapp, result)

    assert_includes formatted, 'Sorry, an error occurred'
    assert_includes formatted, 'Something went wrong'
  end

  # ============================================
  # Tests for render_rag_json_error
  # ============================================

  test 'render_rag_json_error renders bad_request for blank_question' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :blank_question
    )

    @controller.send(:render_rag_json_error, result)

    assert_equal 'error', @controller.rendered_json[:status]
    assert_equal 'Question cannot be empty', @controller.rendered_json[:message]
    assert_equal :bad_request, @controller.rendered_status
  end

  test 'render_rag_json_error renders internal_server_error for config_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :config_error
    )

    @controller.send(:render_rag_json_error, result)

    assert_equal 'error', @controller.rendered_json[:status]
    assert_equal 'RAG service is not properly configured', @controller.rendered_json[:message]
    assert_equal :internal_server_error, @controller.rendered_status
  end

  test 'render_rag_json_error renders bad_gateway for service_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :service_error
    )

    @controller.send(:render_rag_json_error, result)

    assert_equal 'error', @controller.rendered_json[:status]
    assert_equal 'Error querying knowledge base', @controller.rendered_json[:message]
    assert_equal :bad_gateway, @controller.rendered_status
  end

  test 'render_rag_json_error renders internal_server_error for unexpected_error' do
    result = RagQueryConcern::RagResult.new(
      success?: false,
      error_type: :unexpected_error
    )

    @controller.send(:render_rag_json_error, result)

    assert_equal 'error', @controller.rendered_json[:status]
    assert_equal 'Unexpected error processing request', @controller.rendered_json[:message]
    assert_equal :internal_server_error, @controller.rendered_status
  end

  # ============================================
  # Tests for split_for_whatsapp
  # ============================================

  test 'split_for_whatsapp returns single chunk when text fits within limit' do
    short_text = 'A' * 100
    chunks = @controller.send(:split_for_whatsapp, short_text)

    assert_equal 1, chunks.size
    assert_equal short_text, chunks.first
  end

  test 'split_for_whatsapp returns single chunk at exactly the limit' do
    text = 'A' * RagQueryConcern::WHATSAPP_CHUNK_SIZE
    chunks = @controller.send(:split_for_whatsapp, text)

    assert_equal 1, chunks.size
  end

  test 'split_for_whatsapp splits long text into multiple chunks' do
    long_text = 'A' * (RagQueryConcern::WHATSAPP_CHUNK_SIZE * 3)
    chunks = @controller.send(:split_for_whatsapp, long_text)

    assert chunks.size > 1
    chunks.each { |c| assert c.length <= RagQueryConcern::WHATSAPP_CHUNK_SIZE }
  end

  test 'split_for_whatsapp preserves all content across chunks' do
    long_text = ('word ' * 600).strip
    chunks = @controller.send(:split_for_whatsapp, long_text)

    assert chunks.size > 1
    # Reassembled content (ignoring whitespace normalization from rstrip/lstrip) must cover all words
    reassembled = chunks.join(' ')
    original_words = long_text.split
    original_words.each { |w| assert_includes reassembled, w }
  end

  test 'split_for_whatsapp prefers paragraph breaks over hard cuts' do
    para1 = 'First paragraph. ' * 55
    para2 = 'Second paragraph. ' * 55
    text  = "#{para1.rstrip}\n\n#{para2.rstrip}"

    chunks = @controller.send(:split_for_whatsapp, text)

    assert chunks.size >= 2
    # The first chunk must not bleed into para2 content
    assert_not_includes chunks.first, 'Second paragraph'
  end

  test 'split_for_whatsapp each chunk is within the character limit' do
    mixed = (1..50).map { |i| "Paragraph #{i}: " + ('text ' * 20) }.join("\n\n")
    chunks = @controller.send(:split_for_whatsapp, mixed)

    chunks.each_with_index do |chunk, i|
      assert chunk.length <= RagQueryConcern::WHATSAPP_CHUNK_SIZE,
             "Chunk #{i} exceeds limit: #{chunk.length} chars"
    end
  end

  # ============================================
  # Tests for sanitize_answer (Phase 1a)
  # ============================================

  test 'sanitize_answer strips markdown headers but keeps heading text' do
    text = "# Title\n## Subtitle\n### Sub-sub\nbody line"
    out  = @controller.send(:sanitize_answer, text)

    assert_includes out, 'Title'
    assert_includes out, 'Subtitle'
    assert_includes out, 'Sub-sub'
    assert_includes out, 'body line'
    assert_not_includes out, '#'
  end

  test 'sanitize_answer does not strip a hash that appears mid-sentence' do
    text = "Voltage spec is #5 wire gauge required"
    out  = @controller.send(:sanitize_answer, text)
    assert_includes out, '#5 wire gauge'
  end

  test 'sanitize_answer converts a markdown table to a numbered list' do
    text = <<~MD
      Intro line.

      | Parameter | Value | Confidence |
      |---|---|---|
      | Voltage | 380V | LOW |
      | Motor | Trifásico | MEDIA |

      After table line.
    MD

    out = @controller.send(:sanitize_answer, text)

    assert_not_includes out, '|'
    assert_includes out, '① Voltage — Value: 380V — Confidence: LOW'
    assert_includes out, '② Motor — Value: Trifásico — Confidence: MEDIA'
    assert_includes out, 'Intro line.'
    assert_includes out, 'After table line.'
  end

  test 'sanitize_answer collapses 3+ blank lines to 2' do
    text = "line1\n\n\n\nline2"
    out  = @controller.send(:sanitize_answer, text)
    assert_equal "line1\n\nline2", out
  end

  test 'sanitize_answer preserves inline citation markers like [1]' do
    text = "## Section\nThe valve [1] must be closed [2]."
    out  = @controller.send(:sanitize_answer, text)
    assert_includes out, '[1]'
    assert_includes out, '[2]'
  end

  test 'sanitize_answer returns empty string for blank input' do
    assert_equal "", @controller.send(:sanitize_answer, nil)
    assert_equal "", @controller.send(:sanitize_answer, "")
  end

  test 'execute_rag_query sanitizes orchestrator answer before returning' do
    mock = create_mock_orchestrator(
      answer: "## Title\n\n\n\nbody"
    )

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'q')
      assert_equal "Title\n\nbody", result.answer
    end
  end

  # ============================================
  # Tests for output_channel propagation (Phase 1b)
  # ============================================

  test 'execute_rag_query infers :whatsapp output_channel when whatsapp_to is set' do
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    begin
      @controller.send(:execute_rag_query, "hello", whatsapp_to: 'whatsapp:+5550001')
      assert_equal :whatsapp, captured[:kwargs][:output_channel]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query defaults to :web output_channel without whatsapp_to' do
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    begin
      @controller.send(:execute_rag_query, "hello")
      assert_equal :web, captured[:kwargs][:output_channel]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query honors explicit output_channel override' do
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    begin
      @controller.send(:execute_rag_query, "hello", whatsapp_to: 'whatsapp:+5550001', output_channel: :web)
      assert_equal :web, captured[:kwargs][:output_channel]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end
end
