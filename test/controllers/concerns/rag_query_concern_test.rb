# frozen_string_literal: true

require 'test_helper'

class RagQueryConcernTest < ActiveSupport::TestCase
  # Create a test class that includes the concern
  class TestController
    include RagQueryConcern

    # Mock render method for testing render_rag_json_error
    attr_reader :rendered_json, :rendered_status
    attr_accessor :current_account

    def render(json:, status:)
      @rendered_json = json
      @rendered_status = status
    end
  end

  setup do
    @controller = TestController.new
    @controller.current_account = accounts(:legacy)
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
    skip "WA channel disabled for MVP — whatsapp_to / locale stickiness removed"
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
    skip "WA channel disabled for MVP — whatsapp_to / locale stickiness removed"
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
    end
  end

  test 'execute_rag_query parses structured answer for whatsapp channel' do
    skip "WA channel disabled for MVP — whatsapp_to / faceted answer removed"
    structured_raw = <<~ANS
      [INTENT] INSTALLATION
      [DOCS]
      ["Manual Orono A1", "Transformadores.pdf"]
      [RESUMEN]
      Instalación Orono A1 con alimentación desde Transformadores.pdf.
      [RIESGOS]
      ⚠️ LOTO obligatorio.
      [SECCIONES]
      ## Consideraciones iniciales | Manual Orono A1
      Validar plomada.

      ## Componentes | Manual Orono A1, Transformadores.pdf
      ① Contrapeso.
      [MENU]
      1 | ⚠️ Riesgos | __riesgos__
      2 | Consideraciones iniciales | __sec_1__
      3 | Componentes | __sec_2__
      4 | 🔄 Nueva consulta | __new_query__
    ANS
    mock = create_mock_orchestrator(answer: structured_raw, citations: [], session_id: 'sess-1')

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'Como instalo Orono A1?', whatsapp_to: 'whatsapp:+1234')

      assert result.success?
      assert_not_nil result.faceted
      assert_equal :installation, result.faceted.intent
      assert_equal [ 'Manual Orono A1', 'Transformadores.pdf' ], result.faceted.docs
      assert_match(/Instalación Orono A1/, result.faceted.resumen)
      assert_equal 2, result.faceted.sections.length
      assert_equal [ 'Manual Orono A1', 'Transformadores.pdf' ], result.faceted.sections[1][:sources]
      # 1 risk slot + 2 sections + 2 listing slots. Legacy
      # __new_query__ row is stripped by FacetedAnswer.append_list_options.
      assert_equal 5, result.faceted.menu.size
      assert_not result.faceted.menu.any? { |m| m[:kind] == :new_query }, '__new_query__ row must be stripped'
      assert_equal :list_recent, result.faceted.menu[-2][:kind]
      assert_equal :list_all,    result.faceted.menu[-1][:kind]
    end
  end

  test 'execute_rag_query structured falls back to legacy plain answer when labels missing' do
    skip "WA channel disabled for MVP — whatsapp_to / faceted answer removed"
    mock = create_mock_orchestrator(answer: 'Legacy plain answer with no labels.', citations: [], session_id: 's')

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, 'Hola', whatsapp_to: 'whatsapp:+999')

      assert_not_nil result.faceted
      assert result.faceted.legacy?
      # Plain text is retained inside a single synthetic section so the
      # renderer can still ship something, even when the model ignored labels.
      assert_equal 1, result.faceted.sections.length
      assert_match(/Legacy plain answer with no labels\./, result.faceted.sections.first[:body])
    end
  end

  test 'a photo without a question resolves response_locale to Spanish even when the ambient (session) locale is English' do
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) do
      { answer: 'ok', citations: [], session_id: nil, images_uploaded: [ 'foto.jpg' ], response_locale: 'es' }
    end

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    begin
      # I18n.locale simulates session[:locale]=en left behind by the Devise auth-time
      # switcher (LocaleSwitchable) — must not leak into the photo-without-question
      # response_locale (P0 gate). See BedrockRagService.detect_language_from_question fix.
      I18n.with_locale(:en) do
        result = @controller.send(
          :execute_rag_query, '',
          images: [ { data: Base64.strict_encode64('x'), media_type: 'image/jpeg', filename: 'foto.jpg' } ]
        )

        assert result.success?
        assert_equal :es, captured[:kwargs][:response_locale]
        assert_equal 'es', result.response_locale
      end
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
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

  test 'execute_rag_query injects resolver context into the prompt and auto-scopes retrieval for a specific match' do
    KbDocument.delete_all
    doc = KbDocument.create!(
      s3_key:       "uploads/2026-04-10/Esquema SOPREL.pdf",
      display_name: "Esquema SOPREL",
      aliases:      [ "Foremcaro 6118/81" ],
      account:      @controller.current_account
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
      # "SOPREL" is fully uppercase in the question and not a brand — the
      # auto-scope gate (Cambio 1) treats it as specific.
      @controller.send(:execute_rag_query, "que es el Esquema SOPREL?", session_context: "prior ctx")

      assert_includes captured[:kwargs][:session_context], "Query Resolution"
      assert_includes captured[:kwargs][:session_context], "Esquema SOPREL"
      assert_includes captured[:kwargs][:session_context], "prior ctx"
      # No session pin — entity_s3_uris now come from the resolver's specific
      # match (auto-scope), not just from pins.
      assert_equal [ doc.display_s3_uri(KbDocument::KB_BUCKET) ], captured[:kwargs][:entity_s3_uris]
      assert_equal true, captured[:kwargs][:auto_scope_filter]
      # force_entity_filter stays false for auto-scope — keeps BedrockRagService's
      # no-results retry alive (Cambio 1c).
      assert_equal false, captured[:kwargs][:force_entity_filter]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query does not auto-scope when the resolver match is not specific' do
    KbDocument.delete_all
    KbDocument.create!(
      s3_key:       "uploads/2026-04-10/manual_kone.pdf",
      display_name: "Manual Kone",
      aliases:      [],
      account:      @controller.current_account
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
      # "Kone" is a brand, Title-cased (not ALL-CAPS) — not specific, so the
      # match stays prompt-only and retrieval is not narrowed to 3 arbitrary
      # same-brand documents.
      @controller.send(:execute_rag_query, "Tengo un Kone, que reviso primero?")

      assert_equal [], captured[:kwargs][:entity_s3_uris]
      assert_equal false, captured[:kwargs][:auto_scope_filter]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query auto-scope is disabled by RAG_AUTO_SCOPE_ENABLED=false' do
    KbDocument.delete_all
    KbDocument.create!(
      s3_key:       "uploads/2026-04-10/Esquema SOPREL.pdf",
      display_name: "Esquema SOPREL",
      aliases:      [],
      account:      @controller.current_account
    )

    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    original_flag = ENV.fetch("RAG_AUTO_SCOPE_ENABLED", nil)
    ENV["RAG_AUTO_SCOPE_ENABLED"] = "false"

    begin
      @controller.send(:execute_rag_query, "que es el Esquema SOPREL?")

      assert_equal [], captured[:kwargs][:entity_s3_uris]
      assert_equal false, captured[:kwargs][:auto_scope_filter]
    ensure
      original_flag.nil? ? ENV.delete("RAG_AUTO_SCOPE_ENABLED") : ENV["RAG_AUTO_SCOPE_ENABLED"] = original_flag
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

  # ============================================
  # Tests for pin vs. question auto-scope override (Cambio 1)
  # ============================================

  test 'execute_rag_query overrides a disjoint pin when the question has a specific match' do
    KbDocument.delete_all
    pinned_doc = KbDocument.create!(
      s3_key:       "uploads/2026-04-10/xizi FO VF.pdf",
      display_name: "xizi FO VF",
      aliases:      [],
      account:      @controller.current_account
    )
    matched_doc = KbDocument.create!(
      s3_key:       "uploads/2026-04-10/Fallas MPK 708.pdf",
      display_name: "Fallas MPK 708",
      aliases:      [],
      account:      @controller.current_account
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
      @controller.send(
        :execute_rag_query,
        "que revisar en MPK 708?",
        entity_s3_uris: [ pinned_doc.display_s3_uri(KbDocument::KB_BUCKET) ]
      )

      assert_equal [ matched_doc.display_s3_uri(KbDocument::KB_BUCKET) ], captured[:kwargs][:entity_s3_uris]
      assert_equal true, captured[:kwargs][:auto_scope_filter]
      assert_equal false, captured[:kwargs][:force_entity_filter]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query keeps the pin when the question match overlaps it' do
    KbDocument.delete_all
    pinned_doc = KbDocument.create!(
      s3_key:       "uploads/2026-04-10/Fallas MPK 708.pdf",
      display_name: "Fallas MPK 708",
      aliases:      [],
      account:      @controller.current_account
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
      @controller.send(
        :execute_rag_query,
        "que revisar en MPK 708?",
        entity_s3_uris: [ pinned_doc.display_s3_uri(KbDocument::KB_BUCKET) ]
      )

      assert_equal [ pinned_doc.display_s3_uri(KbDocument::KB_BUCKET) ], captured[:kwargs][:entity_s3_uris]
      assert_equal true, captured[:kwargs][:force_entity_filter]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query keeps the pin when the question match is not specific' do
    KbDocument.delete_all
    pinned_doc = KbDocument.create!(
      s3_key:       "uploads/2026-04-10/xizi FO VF.pdf",
      display_name: "xizi FO VF",
      aliases:      [],
      account:      @controller.current_account
    )
    KbDocument.create!(
      s3_key:       "uploads/2026-04-10/manual_kone.pdf",
      display_name: "Manual Kone",
      aliases:      [],
      account:      @controller.current_account
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
      # "Kone" is a bare brand mention — not specific, so it can't dislodge
      # an active pin even though it matches a different document.
      @controller.send(
        :execute_rag_query,
        "Tengo un Kone, que reviso primero?",
        entity_s3_uris: [ pinned_doc.display_s3_uri(KbDocument::KB_BUCKET) ]
      )

      assert_equal [ pinned_doc.display_s3_uri(KbDocument::KB_BUCKET) ], captured[:kwargs][:entity_s3_uris]
      assert_equal true, captured[:kwargs][:force_entity_filter]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query honors an explicit force_entity_filter even when the question would override the pin' do
    KbDocument.delete_all
    pinned_doc = KbDocument.create!(
      s3_key:       "uploads/2026-04-10/xizi FO VF.pdf",
      display_name: "xizi FO VF",
      aliases:      [],
      account:      @controller.current_account
    )
    KbDocument.create!(
      s3_key:       "uploads/2026-04-10/Fallas MPK 708.pdf",
      display_name: "Fallas MPK 708",
      aliases:      [],
      account:      @controller.current_account
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
      @controller.send(
        :execute_rag_query,
        "que revisar en MPK 708?",
        entity_s3_uris: [ pinned_doc.display_s3_uri(KbDocument::KB_BUCKET) ],
        force_entity_filter: true
      )

      assert_equal true, captured[:kwargs][:force_entity_filter]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query narrows multiple pins when the question names one pinned document' do
    manual_uri = "s3://bucket/manual.pdf"
    image_uri = "s3://bucket/photo.jpg"
    session = Struct.new(:active_entities, :conversation_history).new(
      {
        "Manual Plataforma Elevadora Batería" => {
          "canonical_name" => "Manual Plataforma Elevadora Batería",
          "source_uri" => manual_uri,
          "aliases" => [ "Plataforma Tijera Manual" ]
        },
        "Hydraulic Schematic Diagram" => {
          "canonical_name" => "Hydraulic Schematic Diagram",
          "source_uri" => image_uri,
          "aliases" => [ "P41", "esquema hidráulico" ]
        }
      },
      []
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
      @controller.send(
        :execute_rag_query,
        "Según el Manual Plataforma Elevadora Bateria, ¿qué debo revisar?",
        conv_session: session,
        entity_s3_uris: [ manual_uri, image_uri ]
      )

      assert_equal [ manual_uri ], captured.dig(:kwargs, :entity_s3_uris)
      assert_equal true, captured.dig(:kwargs, :force_entity_filter)
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

  # ============================================
  # Tests for response_locale stickiness (conversation continuity)
  # ============================================
  # Field technicians type short, accent-less follow-ups (e.g. "Instalar"). The
  # question-only detector classifies those as :en, which made the assistant
  # switch languages mid-thread. We now bias toward :es when any recent turn
  # was confidently Spanish.

  test 'execute_rag_query keeps Spanish when current question is ambiguous but history is Spanish' do
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    conv_session = Object.new
    conv_session.define_singleton_method(:conversation_history) do
      [
        { "role" => "user",      "content" => "Que relación tienen con mis componentes indexados ?" },
        { "role" => "assistant", "content" => "Tus componentes indexados están directamente interconectados." },
        { "role" => "user",      "content" => "Instalar" }
      ]
    end

    begin
      @controller.send(:execute_rag_query, "Instalar", conv_session: conv_session)
      assert_equal :es, captured[:kwargs][:response_locale],
                   "Short ambiguous follow-ups must inherit Spanish from history"
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query uses English when current question is clearly English despite Spanish history' do
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    conv_session = Object.new
    conv_session.define_singleton_method(:conversation_history) do
      [
        { "role" => "user",      "content" => "Que relacion tienen con mis componentes indexados ?" },
        { "role" => "assistant", "content" => "Tus componentes indexados estan directamente interconectados." },
        { "role" => "user",      "content" => "Instalar" }
      ]
    end

    begin
      question = "What is the maintenance procedure for this elevator?"
      @controller.send(:execute_rag_query, question, conv_session: conv_session)
      assert_equal :en, captured[:kwargs][:response_locale],
                   "Clear English questions must not inherit Spanish from history"
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query stays English when both question and history are English' do
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    conv_session = Object.new
    conv_session.define_singleton_method(:conversation_history) do
      [
        { "role" => "user",      "content" => "What is the maintenance schedule for the controller?" },
        { "role" => "assistant", "content" => "The controller requires inspection every six months." },
        { "role" => "user",      "content" => "Install" }
      ]
    end

    begin
      @controller.send(:execute_rag_query, "Install", conv_session: conv_session)
      assert_equal :en, captured[:kwargs][:response_locale]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  test 'execute_rag_query honors explicit response_locale override regardless of history' do
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }

    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end

    conv_session = Object.new
    conv_session.define_singleton_method(:conversation_history) do
      [ { "role" => "user", "content" => "Que es el cuadro de maniobra ?" } ]
    end

    begin
      @controller.send(:execute_rag_query, "Instalar", conv_session: conv_session, response_locale: :en)
      assert_equal :en, captured[:kwargs][:response_locale]
    ensure
      QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
    end
  end

  # ============================================
  # Tests for images_uploaded propagation
  # ============================================

  test 'execute_rag_query forwards images_uploaded from orchestrator result' do
    mock = Object.new
    mock.define_singleton_method(:execute) do
      {
        answer:           "Tu imagen está siendo indexada en la Base de Conocimiento.",
        citations:        [],
        session_id:       nil,
        images_uploaded:  [ "diagram.jpg" ]
      }
    end

    with_mock_orchestrator(mock) do
      result = @controller.send(:execute_rag_query, "", images: [ { data: "x", media_type: "image/jpeg" } ])

      assert result.success?
      assert_equal [ "diagram.jpg" ], result.images_uploaded
    end
  end

  test 'execute_rag_query honors explicit output_channel override' do
    skip "WA channel disabled for MVP — whatsapp_to removed from execute_rag_query"
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

  # ============================================
  # Caso Jesús 2026-09-16
  # ============================================

  JESUS_TURNS = [
    { ts: "2026-09-16T10:49:41-03:00", role: "user",
      content: "Hola, tengo una falla eléctrica en un elevador hidráulico Elemont, con imanes y tarjeta Cea15" },
    { ts: "2026-09-16T10:49:47-03:00", role: "assistant",
      content: "La documentación disponible del Elemont Montacargas Hidráulico Modelo MH no contiene información específica sobre la tarjeta CEA15." },
    { ts: "2026-09-16T10:50:55-03:00", role: "user",
      content: "La falla es en la puerta número 1 el equipo no magnetiza bien el imán de la puerta para que inicie movimiento." },
    { ts: "2026-09-16T10:51:02-03:00", role: "assistant",
      content: "La documentación del Montacargas Hidráulico Modelo MH identifica componentes de la puerta nivel 1 pero no el imán." },
    { ts: "2026-09-16T10:51:54-03:00", role: "user",
      content: "Elemont Montacargas Hidraulico Modelo MH" }
  ].freeze

  AUGUST_TURNS = [
    { ts: "2026-08-31T17:30:11-04:00", role: "user",    content: "Elemont Montacargas Hidraulico Modelo MH" },
    { ts: "2026-08-31T17:30:21-04:00", role: "assistant", content: "El Elemont Montacargas Hidráulico Modelo MH es un equipo de elevación fabricado por Elemont Limitada." }
  ].freeze

  def build_jesus_catalog
    KbDocument.delete_all
    account = @controller.current_account
    elemont = KbDocument.create!(
      account: account,
      s3_key: "bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf",
      display_name: "Elemont Montacargas Hidraulico Modelo MH",
      aliases: [ "Montacargas Hidraulico", "Modelo MH", "ELEMONT-N/A", "Tablero de Control",
                 "Instalaciones Electricas", "Elemont", "Santa Adela 9540 Maipu",
                 "Montacargas 2N Temporizado", "TDC", "MELSEC FX 3S", "Mitsubishi Electric",
                 "Distribucion TDC", "ROL 2740", "Diagrama Unilineal Tablero Control",
                 "Instalaciones Electricas MH" ]
    )
    cea15 = KbDocument.create!(
      account: account,
      s3_key: "bulk_uploads/1/2026-08-31/manual-cea15p.pdf",
      display_name: "manual-cea15p",
      aliases: [ "DD549-R05", "manual controlador ascensor", "controlador ascensor", "CEA15P",
                 "CEA15+", "controlador ascensor CEA15", "Controles S.A.",
                 "Serie Seguridad Manual SM", "AEXT", "ATACM" ]
    )
    forklift = KbDocument.create!(
      account: account,
      s3_key: "uploads/1/a2f1d186-48ce-46e4-a870-3962c7fd5967/original.pdf",
      display_name: "685970470-A-Series-1-0t-3-5t-Electric-four-wheel-Forklift-Truck-Service-Manual-5bNot-CE-5d-1",
      aliases: [ "Carretilla eléctrica" ]
    )
    [ elemont, cea15, forklift ]
  end

  JESUS_ACCOUNT1_CATALOG_PATH = Rails.root.join(
    "test/fixtures/files/jesus_account1_catalog_2026-09-16.json"
  )

  # Production account-1 catalog (19 docs) with snapshot created_at. Concatenating
  # T1+T2 into one resolver call expels CEA15 from MAX_MATCHES=3; the 3-doc
  # catalog in build_jesus_catalog cannot reproduce that cut.
  def build_jesus_full_account_catalog
    KbDocument.delete_all
    account = @controller.current_account
    docs = JSON.parse(File.read(JESUS_ACCOUNT1_CATALOG_PATH)).fetch("documents").map do |row|
      KbDocument.create!(
        account: account,
        s3_key: row.fetch("s3_key"),
        display_name: row.fetch("display_name"),
        aliases: row.fetch("aliases"),
        created_at: Time.zone.parse(row.fetch("created_at"))
      )
    end
    elemont  = docs.find { |doc| doc.s3_key.include?("Montacargas 2N Temporizado-1 (1).pdf") }
    cea15    = docs.find { |doc| doc.s3_key.end_with?("manual-cea15p.pdf") }
    forklift = docs.find { |doc| doc.s3_key.include?("a2f1d186-48ce-46e4-a870-3962c7fd5967") }
    [ elemont, cea15, forklift ]
  end

  # @param turn [Integer] 1, 2 o 3: cuántos turnos de usuario del 16-sep ya están en el historial
  def build_jesus_session(elemont, turn:)
    history_size = { 1 => 1, 2 => 3, 3 => 5 }.fetch(turn)
    ConversationSession.create!(
      identifier: "web:jesus_#{SecureRandom.hex(4)}",
      channel: "web",
      account: @controller.current_account,
      expires_at: 30.days.from_now,
      active_entities: {
        elemont.display_name => {
          "source" => "user_pin",
          "kb_document_id" => elemont.id,
          "source_uri" => elemont.display_s3_uri(KbDocument::KB_BUCKET),
          "entity_type" => "document",
          "canonical_name" => elemont.display_name,
          "aliases" => elemont.aliases,
          "added_at" => "2026-09-16T10:51:51-03:00"
        }
      },
      conversation_history: (AUGUST_TURNS + JESUS_TURNS.first(history_size)).map(&:stringify_keys)
    )
  end

  def with_captured_orchestrator
    captured = {}
    mock = Object.new
    mock.define_singleton_method(:execute) { { answer: "ok", citations: [], session_id: "s" } }
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |*_args, **kwargs|
      captured[:kwargs] = kwargs
      mock
    end
    yield captured
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*a, **k| original_new.call(*a, **k) }
  end

  def query_resolution_main_block(session_context)
    text = session_context.to_s
    return "" unless text.include?("## Query Resolution")

    block = text.split("## Query Resolution", 2).last
    block = block.split(/\n## /).first
    block.split("Also in catalog but NOT consulted this turn", 2).first.to_s
  end

  def jesus_uris(elemont, cea15, forklift = nil)
    {
      e: elemont.display_s3_uri(KbDocument::KB_BUCKET),
      c: cea15.display_s3_uri(KbDocument::KB_BUCKET),
      f: forklift&.display_s3_uri(KbDocument::KB_BUCKET)
    }
  end

  test "jesus turn 1 extends the pin with the CEA15 manual" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 1)
    question = JESUS_TURNS[0][:content]

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[0][:ts]) do
        @controller.send(
          :execute_rag_query, question,
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_equal [ uris[:e], uris[:c] ], captured[:kwargs][:entity_s3_uris],
                   "jesus turn 1 extends the pin with the CEA15 manual; today returns pin-only"
      assert_equal true, captured[:kwargs][:auto_scope_filter]
      assert_equal false, captured[:kwargs][:force_entity_filter]
      assert_not_includes captured[:kwargs][:session_context].to_s, "## Selection Turn"
    end
  end

  test "jesus turn 1 never scopes the forklift manual" do
    elemont, cea15, forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15, forklift)
    session = build_jesus_session(elemont, turn: 1)
    question = JESUS_TURNS[0][:content]

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[0][:ts]) do
        @controller.send(
          :execute_rag_query, question,
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_not_includes Array(captured[:kwargs][:entity_s3_uris]), uris[:f],
                      "jesus turn 1 never scopes the forklift manual matched by eléctrica"
    end
  end

  test "jesus turn 2 inherits the episode scope" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 2)
    question = JESUS_TURNS[2][:content]

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[2][:ts]) do
        @controller.send(
          :execute_rag_query, question,
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_equal [ uris[:e], uris[:c] ], captured[:kwargs][:entity_s3_uris],
                   "jesus turn 2 inherits the episode scope; today returns pin-only"
      assert_equal true, captured[:kwargs][:auto_scope_filter]
      assert_equal true, captured[:kwargs][:force_entity_filter]
      assert_not_includes captured[:kwargs][:session_context].to_s, "## Selection Turn"
      assert_includes query_resolution_main_block(captured[:kwargs][:session_context].to_s), "manual-cea15p"
    end
  end

  test "jesus turn 3 keeps the episode scope and offers to continue" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 3)
    question = JESUS_TURNS[4][:content]
    previous = JESUS_TURNS[2][:content]

    result = nil
    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
        result = @controller.send(
          :execute_rag_query, question,
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_nil captured[:kwargs], "la puerta no debe instanciar el orquestador"
      assert_equal "deterministic_selection_gate", result.generation_mode
      assert_equal false, result.model_invoked
      assert_nil result.session_id
      assert_equal 2, Array(result.quick_replies).size
      assert_includes result.answer, "?"
      assert_no_match Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN, result.answer
      assert_not_includes result.answer, elemont.display_name
    end

    replies = Array(result.quick_replies)
    assert_equal 2, replies.size,
                 "jesus turn 3 offers to continue; today quick_replies is nil"
    assert_equal "Continuar: #{previous.truncate(60)}", replies[0][:label] || replies[0]["label"]
    assert_equal previous, replies[0][:query] || replies[0]["query"]
    assert_equal "Resumen del documento", replies[1][:label] || replies[1]["label"]
    assert_equal "Resumen del documento #{question}", replies[1][:query] || replies[1]["query"]
  end

  test "jesus turn 3 inherits CEA15 with the full account catalog" do
    elemont, cea15, forklift = build_jesus_full_account_catalog
    uris = jesus_uris(elemont, cea15, forklift)
    session = build_jesus_session(elemont, turn: 3)
    question = JESUS_TURNS[4][:content]

    travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
      _matches, candidates = @controller.send(
        :inherit_episode_scope, question, session, @controller.current_account
      )
      assert_equal [ uris[:c] ], candidates
      assert_not_includes candidates, uris[:f]
    end

    result = nil
    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
        result = @controller.send(
          :execute_rag_query, question,
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_nil captured[:kwargs], "la puerta no debe instanciar el orquestador"
      assert_equal "deterministic_selection_gate", result.generation_mode
      assert_equal false, result.model_invoked
      assert_nil result.session_id
      assert_equal 2, Array(result.quick_replies).size
      assert_includes result.answer, "?"
      assert_no_match Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN, result.answer
      assert_not_includes result.answer, elemont.display_name
    end
  end

  test "jesus turn 3 selection context names the pin and the active problem" do
    elemont, cea15, _forklift = build_jesus_catalog
    session = build_jesus_session(elemont, turn: 3)
    question = JESUS_TURNS[4][:content]
    previous = JESUS_TURNS[2][:content]

    travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
      ctx = @controller.send(
        :merge_selection_intent, SessionContextBuilder.build(session), question, session
      )
      assert_includes ctx, "## Selection Turn"
      assert_includes ctx, question
      assert_includes ctx, previous
      assert_includes ctx, "Do not write a general document summary"
      assert_includes ctx, "even if Session Discipline would treat them as unpinned"
    end
  end

  test "jesus turn 3 selection context also matches a real pin alias" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 2)
    alias_question = "Modelo MH"

    result = nil
    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
        result = @controller.send(
          :execute_rag_query, alias_question,
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_nil captured[:kwargs], "la puerta no debe instanciar el orquestador"
      assert_equal "deterministic_selection_gate", result.generation_mode
      assert_equal false, result.model_invoked
      assert_nil result.session_id
      replies = Array(result.quick_replies)
      assert_equal 2, replies.size
      assert_includes result.answer, "?"
      assert_no_match Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN, result.answer
      assert_not_includes result.answer, elemont.display_name
      assert_equal "Resumen del documento Modelo MH", replies[1][:query] || replies[1]["query"]
    end
  end

  test "jesus turn 3 inherited scope cannot opt out of force_entity_filter" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 3)

    result = nil
    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
        result = @controller.send(
          :execute_rag_query, JESUS_TURNS[4][:content],
          conv_session: session,
          entity_s3_uris: [ uris[:e] ],
          force_entity_filter: false
        )
      end

      assert_nil captured[:kwargs], "la puerta no debe instanciar el orquestador"
      assert_equal "deterministic_selection_gate", result.generation_mode
      assert_equal false, result.model_invoked
      assert_nil result.session_id
      assert_equal 2, Array(result.quick_replies).size
      assert_includes result.answer, "?"
      assert_no_match Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN, result.answer
      assert_not_includes result.answer, elemont.display_name
    end
  end

  test "jesus turn 1 caller force_entity_filter false keeps pin_extended precedence" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 1)

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[0][:ts]) do
        @controller.send(
          :execute_rag_query, JESUS_TURNS[0][:content],
          conv_session: session,
          entity_s3_uris: [ uris[:e] ],
          force_entity_filter: false
        )
      end

      assert_equal [ uris[:e], uris[:c] ], captured[:kwargs][:entity_s3_uris]
      assert_equal false, captured[:kwargs][:force_entity_filter]
    end
  end

  test "jesus explicit summary request does not inject selection intent" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 3)
    question = "Resumen del documento #{JESUS_TURNS[4][:content]}"

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
        @controller.send(
          :execute_rag_query, question,
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_not_nil captured[:kwargs], "el quick reply de resumen no debe reentrar en la puerta"
      assert_not_includes captured[:kwargs][:session_context].to_s, "## Selection Turn"
    end
  end

  test "jesus selection intent is skipped when the episode has expired" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 3)
    expired_at = Time.zone.parse(JESUS_TURNS[2][:ts]) + 4.hours + 1.second

    with_captured_orchestrator do |captured|
      travel_to expired_at do
        @controller.send(
          :execute_rag_query, JESUS_TURNS[4][:content],
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_not_nil captured[:kwargs]
      assert_not_includes captured[:kwargs][:session_context].to_s, "## Selection Turn"
      assert_equal [ uris[:e] ], captured[:kwargs][:entity_s3_uris]
    end
  end

  test "jesus selection intent keeps preexisting quick replies" do
    elemont, _cea15, _forklift = build_jesus_catalog
    session = build_jesus_session(elemont, turn: 3)
    existing = [ { label: "Otra", query: "otra" } ]

    travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
      assert_equal existing, @controller.send(
        :selection_quick_replies, JESUS_TURNS[4][:content], session, existing
      )
    end
  end

  test "jesus turn 3 selection gate answers in the session locale" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 3)

    result = nil
    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
        result = @controller.send(
          :execute_rag_query, JESUS_TURNS[4][:content],
          conv_session: session,
          entity_s3_uris: [ uris[:e] ],
          response_locale: :en
        )
      end

      assert_nil captured[:kwargs], "la puerta no debe instanciar el orquestador"
      assert_equal "deterministic_selection_gate", result.generation_mode
      assert_equal I18n.t("rag.selection_turn_prompt", locale: :en), result.answer
    end
  end

  test "jesus turn 3 selection gate does not fire outside web" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 3)

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
        @controller.send(
          :execute_rag_query, JESUS_TURNS[4][:content],
          conv_session: session,
          entity_s3_uris: [ uris[:e] ],
          output_channel: :whatsapp
        )
      end

      assert_not_nil captured[:kwargs]
      assert_equal [ uris[:e], uris[:c] ], captured[:kwargs][:entity_s3_uris]
    end
  end

  test "jesus turn 3 selection gate does not fire with an attachment" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 3)

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
        @controller.send(
          :execute_rag_query, JESUS_TURNS[4][:content],
          conv_session: session,
          entity_s3_uris: [ uris[:e] ],
          images: [ { data: "x", media_type: "image/png" } ]
        )
      end

      assert_not_nil captured[:kwargs]
    end
  end

  test "jesus turn 2 inherited scope cannot opt out of force_entity_filter" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 2)

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[2][:ts]) do
        @controller.send(
          :execute_rag_query, JESUS_TURNS[2][:content],
          conv_session: session,
          entity_s3_uris: [ uris[:e] ],
          force_entity_filter: false
        )
      end

      assert_equal [ uris[:e], uris[:c] ], captured[:kwargs][:entity_s3_uris]
      assert_equal true, captured[:kwargs][:force_entity_filter]
    end
  end

  test "resolve_retrieval_scope covers the pin/question contract" do
    x = "s3://b/x.pdf"
    y = "s3://b/y.pdf"
    e = "s3://b/elemont.pdf"
    c = "s3://b/cea15.pdf"

    cases = [
      { pinned: [], candidates: [ y ], mentioned: [ y ],
        uris: [ y ], auto: true, force: false, reason: "auto_scope" },
      { pinned: [], candidates: [], mentioned: [],
        uris: [], auto: false, force: false, reason: "open" },
      { pinned: [ x ], candidates: [], mentioned: [],
        uris: [ x ], auto: false, force: true, reason: "pin_only" },
      { pinned: [ x ], candidates: [ x ], mentioned: [ x ],
        uris: [ x ], auto: false, force: true, reason: "pin_kept" },
      { pinned: [ e ], candidates: [ c ], mentioned: [ e, c ],
        uris: [ e, c ], auto: true, force: false, reason: "pin_extended" },
      { pinned: [ x ], candidates: [ y ], mentioned: [ y ],
        uris: [ y ], auto: true, force: false, reason: "pin_overridden" }
    ]

    cases.each do |row|
      scope = @controller.send(
        :resolve_retrieval_scope,
        pinned_uris: row[:pinned],
        candidate_uris: row[:candidates],
        mentioned_uris: row[:mentioned]
      )
      assert_equal row[:uris], scope.uris, "uris for #{row[:reason]}"
      assert_equal row[:auto], scope.auto_scope_filter, "auto_scope_filter for #{row[:reason]}"
      assert_equal row[:force], scope.force_entity_filter, "force_entity_filter for #{row[:reason]}"
      assert_equal row[:reason], scope.reason
    end
  end

  test "query resolution lists all matches when retrieval is open" do
    elemont, cea15, _forklift = build_jesus_catalog
    matches = [
      KbDocumentResolver::MatchResult.new(document: elemont, score: 1, matched_tokens: [ "Elemont" ]),
      KbDocumentResolver::MatchResult.new(document: cea15, score: 1, matched_tokens: [ "Cea15" ])
    ]

    ctx = @controller.send(:merge_resolver_context, "prior", matches, in_scope_uris: [])
    main = query_resolution_main_block(ctx)
    assert_includes main, elemont.display_name
    assert_includes main, cea15.display_name
    assert_not_includes ctx, "Also in catalog but NOT consulted this turn"
  end

  test "query resolution main list only includes in-scope matches" do
    elemont, cea15, _forklift = build_jesus_catalog
    matches = [
      KbDocumentResolver::MatchResult.new(document: elemont, score: 1, matched_tokens: [ "Elemont" ]),
      KbDocumentResolver::MatchResult.new(document: cea15, score: 1, matched_tokens: [ "Cea15" ])
    ]
    in_scope = [ elemont.display_s3_uri(KbDocument::KB_BUCKET) ]

    ctx = @controller.send(:merge_resolver_context, nil, matches, in_scope_uris: in_scope)
    main = query_resolution_main_block(ctx)
    assert_includes main, elemont.display_name
    assert_not_includes main, cea15.display_name
  end

  test "query resolution lists out-of-scope matches after the not-consulted line" do
    elemont, cea15, _forklift = build_jesus_catalog
    matches = [
      KbDocumentResolver::MatchResult.new(document: elemont, score: 1, matched_tokens: [ "Elemont" ]),
      KbDocumentResolver::MatchResult.new(document: cea15, score: 1, matched_tokens: [ "Cea15" ])
    ]
    in_scope = [ elemont.display_s3_uri(KbDocument::KB_BUCKET) ]

    ctx = @controller.send(:merge_resolver_context, nil, matches, in_scope_uris: in_scope)
    marker = "Also in catalog but NOT consulted this turn (do not cite, do not describe their content):"
    assert_includes ctx, marker
    after = ctx.split(marker, 2).last
    assert_includes after, cea15.display_name
    assert_not_includes query_resolution_main_block(ctx), cea15.display_name
  end

  test "query resolution omits the block when no matches remain" do
    ctx = @controller.send(:merge_resolver_context, "prior", [], in_scope_uris: [ "s3://b/x.pdf" ])
    assert_equal "prior", ctx
    assert_not_includes ctx.to_s, "Query Resolution"
  end

  test "query resolution keeps the existing line format" do
    elemont, _cea15, _forklift = build_jesus_catalog
    matches = [
      KbDocumentResolver::MatchResult.new(document: elemont, score: 1, matched_tokens: [ "Elemont" ])
    ]

    ctx = @controller.send(
      :merge_resolver_context, nil, matches,
      in_scope_uris: [ elemont.display_s3_uri(KbDocument::KB_BUCKET) ]
    )
    aliases = Array(elemont.aliases).map(&:to_s).compact_blank.first(5).join(", ")
    expected = "- \"#{elemont.display_name}\" → #{elemont.s3_key} (aka: #{aliases})"
    assert_includes ctx, expected
  end

  test "query resolution block only names documents inside the retrieval scope" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 1)
    question = JESUS_TURNS[0][:content]
    original_flag = ENV.fetch("RAG_AUTO_SCOPE_ENABLED", nil)
    ENV["RAG_AUTO_SCOPE_ENABLED"] = "false"

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[0][:ts]) do
        @controller.send(
          :execute_rag_query, question,
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_equal [ uris[:e] ], captured[:kwargs][:entity_s3_uris]
      main = query_resolution_main_block(captured[:kwargs][:session_context])
      assert_not_includes main, cea15.display_name,
                          "query resolution main block must not name manual-cea15p when retrieval is pin-only"
    end
  ensure
    original_flag.nil? ? ENV.delete("RAG_AUTO_SCOPE_ENABLED") : ENV["RAG_AUTO_SCOPE_ENABLED"] = original_flag
  end

  test "jesus episode expires after four hours and keeps the pin only" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 2)
    question = JESUS_TURNS[2][:content]
    expired_at = Time.zone.parse(JESUS_TURNS[0][:ts]) + 4.hours + 1.second

    with_captured_orchestrator do |captured|
      travel_to expired_at do
        @controller.send(
          :execute_rag_query, question,
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_equal [ uris[:e] ], captured[:kwargs][:entity_s3_uris]
      assert_equal false, captured[:kwargs][:auto_scope_filter]
      assert_equal true, captured[:kwargs][:force_entity_filter]
    end
  end

  test "jesus episode is replaced when the question names a disjoint designator" do
    elemont, cea15, _forklift = build_jesus_catalog
    mpk = KbDocument.create!(
      account: @controller.current_account,
      s3_key: "uploads/2026-04-10/Fallas MPK 708.pdf",
      display_name: "Fallas MPK 708",
      aliases: []
    )
    uris = jesus_uris(elemont, cea15)
    mpk_uri = mpk.display_s3_uri(KbDocument::KB_BUCKET)
    session = build_jesus_session(elemont, turn: 2)

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[2][:ts]) do
        @controller.send(
          :execute_rag_query, "Código de falla en MPK 708",
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_equal [ mpk_uri ], captured[:kwargs][:entity_s3_uris]
      assert_equal true, captured[:kwargs][:auto_scope_filter]
      assert_equal false, captured[:kwargs][:force_entity_filter]
      assert_not_includes captured[:kwargs][:session_context].to_s, "## Selection Turn"
    end
  end

  test "jesus pin stays exclusive when auto-scope is disabled" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    session = build_jesus_session(elemont, turn: 1)
    original_flag = ENV.fetch("RAG_AUTO_SCOPE_ENABLED", nil)
    ENV["RAG_AUTO_SCOPE_ENABLED"] = "false"

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[0][:ts]) do
        @controller.send(
          :execute_rag_query, JESUS_TURNS[0][:content],
          conv_session: session,
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_equal [ uris[:e] ], captured[:kwargs][:entity_s3_uris]
      assert_equal false, captured[:kwargs][:auto_scope_filter]
      assert_equal true, captured[:kwargs][:force_entity_filter]
    end
  ensure
    original_flag.nil? ? ENV.delete("RAG_AUTO_SCOPE_ENABLED") : ENV["RAG_AUTO_SCOPE_ENABLED"] = original_flag
  end

  test "jesus episode inheritance and selection replies are skipped when the episode flag is off" do
    elemont, cea15, _forklift = build_jesus_catalog
    uris = jesus_uris(elemont, cea15)
    original_flag = ENV.fetch("RAG_EPISODE_SCOPE_ENABLED", nil)
    ENV["RAG_EPISODE_SCOPE_ENABLED"] = "false"

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[0][:ts]) do
        @controller.send(
          :execute_rag_query, JESUS_TURNS[0][:content],
          conv_session: build_jesus_session(elemont, turn: 1),
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_equal [ uris[:e], uris[:c] ], captured[:kwargs][:entity_s3_uris],
                   "P0 pin_extended must stay intact with the episode flag off"
    end

    result = nil
    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[2][:ts]) do
        result = @controller.send(
          :execute_rag_query, JESUS_TURNS[2][:content],
          conv_session: build_jesus_session(elemont, turn: 2),
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_equal [ uris[:e] ], captured[:kwargs][:entity_s3_uris]
      assert_equal false, captured[:kwargs][:auto_scope_filter]
      assert_equal true, captured[:kwargs][:force_entity_filter]
    end

    with_captured_orchestrator do |captured|
      travel_to Time.zone.parse(JESUS_TURNS[4][:ts]) do
        result = @controller.send(
          :execute_rag_query, JESUS_TURNS[4][:content],
          conv_session: build_jesus_session(elemont, turn: 3),
          entity_s3_uris: [ uris[:e] ]
        )
      end

      assert_equal [ uris[:e] ], captured[:kwargs][:entity_s3_uris]
      assert_not_includes captured[:kwargs][:session_context].to_s, "## Selection Turn"
    end
    assert_nil result.quick_replies
  ensure
    original_flag.nil? ? ENV.delete("RAG_EPISODE_SCOPE_ENABLED") : ENV["RAG_EPISODE_SCOPE_ENABLED"] = original_flag
  end
end
