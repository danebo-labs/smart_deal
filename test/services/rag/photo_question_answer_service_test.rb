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
    @original_gs_flag = ENV.fetch("RAG_GROUNDED_SYNTHESIS_ENABLED", nil)
    ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
    @orig_rag_query = BedrockRagService.instance_method(:query)
    KbDocument.create!(
      account: @account, s3_key: "uploads/urm.pdf", display_name: "Manual de URM",
      aliases: [ "GECB", "Terminal portátil OTIS", "System Menu" ], document_uid: SecureRandom.uuid
    )
  end

  teardown do
    BedrockRagService.define_method(:query, @orig_rag_query)
    @previous_flag.nil? ? ENV.delete("PHOTO_QUESTION_RAG_ENABLED") : ENV["PHOTO_QUESTION_RAG_ENABLED"] = @previous_flag
    @previous_sources_flag.nil? ? ENV.delete("SHOW_RAG_SOURCES") : ENV["SHOW_RAG_SOURCES"] = @previous_sources_flag
    if @original_gs_flag.nil?
      ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
    else
      ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = @original_gs_flag
    end
  end

  test "anchors the question only with catalog-resolved tokens, omitting unresolved OCR text" do
    captured = nil
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured = { question: question, kwargs: kwargs }
      { answer: "Es un GECB [1]", citations: [ { number: 1, title: "Manual" } ], session_id: nil }
    end

    result = build_service(question: "Que equipo es y que está mostrando la pantalla?").call

    assert_includes captured[:question], "Que equipo es y que está mostrando la pantalla?"
    assert_includes captured[:question], "GECB"
    assert_not_includes captured[:question], "System=1"
    assert_not_includes captured[:question], "Tools=2"
    assert_not_includes captured[:question], "UNKNOWN"
    assert result
    assert_equal "Es un GECB [1]", result[:answer]
  end

  test "no catalog match sends the literal question with no anchor suffix" do
    captured = nil
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured = { question: question, kwargs: kwargs }
      { answer: I18n.t("rag.data_not_available", locale: :es), citations: [], session_id: nil }
    end
    KbDocument.create!(
      account: @account, s3_key: "uploads/motor.pdf", display_name: "Manual de motores",
      aliases: [ "ajuste motor" ], document_uid: SecureRandom.uuid
    )

    photo_value = {
      canonical_name: "Fijacion de Cables Motor",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "UNKNOWN",
      visible_codes: [ "Caracteristicas Motor", "Fijacion de Cables", "000A60961010" ]
    }
    question = "Como se inspecciona la fijacion de cables"

    build_service(question: question, photo_value: photo_value).call

    assert_equal question, captured[:question]
  end

  test "generic words living in an alias never anchor" do
    captured = nil
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured = { question: question, kwargs: kwargs }
      { answer: "ok", citations: [], session_id: nil }
    end
    KbDocument.create!(
      account: @account, s3_key: "uploads/module.pdf", display_name: "Manual de modulos",
      aliases: [ "MODULE", "FUNCTION" ], document_uid: SecureRandom.uuid
    )

    photo_value = {
      canonical_name: "Herramienta portátil programadora",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "UNKNOWN",
      visible_codes: [ "GECB - Menu", "System=1 Tools=2", "MODULE", "FUNCTION", "SET" ]
    }
    question = "Que es este dispositivo y que se ve en la pantalla ?"

    build_service(question: question, photo_value: photo_value).call

    assert_equal question, captured[:question]
  end

  test "digit-bearing visible code that the catalog knows anchors" do
    captured = nil
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured = { question: question, kwargs: kwargs }
      { answer: "ok", citations: [], session_id: nil }
    end
    KbDocument.create!(
      account: @account, s3_key: "uploads/mpk.pdf", display_name: "Manual de placa",
      aliases: [ "MPK 708A" ], document_uid: SecureRandom.uuid
    )

    photo_value = {
      canonical_name: "Placa de control",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "UNKNOWN",
      visible_codes: [ "708A" ]
    }

    build_service(question: "Que indica esta placa?", photo_value: photo_value).call

    assert captured[:question].end_with?("(708A)")
  end

  test "model_visible designator anchors even when canonical_name is generic" do
    captured = nil
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured = { question: question, kwargs: kwargs }
      { answer: "ok", citations: [], session_id: nil }
    end

    photo_value = {
      canonical_name: "Herramienta portátil",
      manufacturer: "UNKNOWN",
      model_visible: "GECB",
      condition: "UNKNOWN",
      visible_codes: [ "UNKNOWN" ]
    }

    build_service(question: "Que muestra la pantalla?", photo_value: photo_value).call

    assert_includes captured[:question], "(GECB)"
  end

  test "a resolved token already present in the question is omitted from the suffix" do
    captured = nil
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured = { question: question, kwargs: kwargs }
      { answer: "ok", citations: [], session_id: nil }
    end

    build_service(question: "Que muestra el GECB?").call

    assert_equal "Que muestra el GECB?", captured[:question]
  end

  test "without an account, the anchor is skipped and the resolver is never called" do
    called = false
    original_resolve = KbDocumentResolver.method(:resolve_scoped)
    KbDocumentResolver.define_singleton_method(:resolve_scoped) do |*args, **kwargs|
      called = true
      original_resolve.call(*args, **kwargs)
    end

    service = Rag::PhotoQuestionAnswerService.new(
      question: "Que equipo es y que está mostrando la pantalla?",
      photo_value: @photo_value,
      session: @session,
      account: nil,
      user_id: users(:one).id,
      correlation_id: "photo:test",
      locale: "es"
    )

    assert_equal "", service.send(:anchor_suffix)
    assert_not called, "resolve_scoped must not run without an account"
  ensure
    KbDocumentResolver.define_singleton_method(:resolve_scoped) { |*a, **kw| original_resolve.call(*a, **kw) } if original_resolve
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
    assert_not_includes context, "substituting"
    assert_not_includes context, "Never infer"
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

  test "passes conversation_session_id through to QueryOrchestratorService for traceability" do
    captured_kwargs = nil
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |question, **kwargs|
      captured_kwargs = kwargs
      original_new.call(question, **kwargs)
    end
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      { answer: "ok", citations: [], session_id: nil }
    end

    build_service(question: "Que es esto?").call

    assert_equal @session.id, captured_kwargs[:conversation_session_id]
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |question, **kwargs| original_new.call(question, **kwargs) } if original_new
  end

  test "returns nil when the RAG call does not succeed" do
    BedrockRagService.define_method(:query) do |*|
      raise BedrockRagService::BedrockServiceError, "boom"
    end

    result = build_service(question: "Que es esto?").call

    assert_nil result
  end

  test "H9 names a screen document when grounded synthesis is on and sheet titles are visible" do
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = "true"
    photo_value = {
      canonical_name: "Fijacion de Cables Motor",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "UNKNOWN",
      visible_codes: [ "Características Motor", "Fijación de Cables" ]
    }

    block = build_service(question: "Como se ajustan", photo_value: photo_value).send(:photo_evidence_block)

    assert_includes block, "document on a screen"
    assert_includes block, "not the manufacturer"
    assert_not_includes block, "BOLIVAR"
  end

  test "H9 stays off when the flag is off even if sheet titles are visible" do
    photo_value = {
      canonical_name: "Fijacion de Cables Motor",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "UNKNOWN",
      visible_codes: [ "Caracteristicas Motor", "Fijacion de Cables" ]
    }

    block = build_service(question: "Como se ajustan", photo_value: photo_value).send(:photo_evidence_block)

    assert_not_includes block, "document on a screen"
  end

  test "H9 detects a sheet title plus a plant-style identifier without naming a site" do
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = "true"
    photo_value = {
      canonical_name: "UNKNOWN",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "UNKNOWN",
      visible_codes: [ "Hoja de Datos", "SITIO 12" ]
    }

    block = build_service(question: "Que muestra", photo_value: photo_value).send(:photo_evidence_block)

    assert_includes block, "document on a screen"
  end

  test "a named brand on a different photographed component is stated before any procedure" do
    photo_value = {
      canonical_name: "Transformador trifásico con fusibles",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "DEGRADED",
      visible_codes: [ "FEDEOSTRI 6N6", "000AC006T0T0" ]
    }

    block = build_service(
      question: "Cómo se ajustan los resortes de la fijación de cables ? es Fuji Yida",
      photo_value: photo_value
    ).send(:photo_evidence_block)

    assert_includes block, "Say that mismatch first"
    assert_includes block, "another manufacturer"
    assert_includes block, "Component: Transformador trifásico con fusibles"
    assert_operator block.length, :<=, Rag::PhotoQuestionAnswerService::EVIDENCE_BLOCK_MAX_CHARS
  end

  test "an illegible label on the named component does not claim a brand mismatch" do
    photo_value = {
      canonical_name: "Fijación de cables",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "UNKNOWN",
      visible_codes: [ "UNKNOWN" ]
    }

    block = build_service(
      question: "Cómo se ajustan los resortes de la fijación de cables ? es Fuji Yida",
      photo_value: photo_value
    ).send(:photo_evidence_block)

    assert_not_includes block, "Say that mismatch first"
  end

  test "a screen question without a brand does not claim a component mismatch" do
    block = build_service(question: "Que está mostrando la pantalla?").send(:photo_evidence_block)

    assert_not_includes block, "Say that mismatch first"
  end

  test "H9 does not fire on a controller screen" do
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = "true"

    block = build_service(question: "Que muestra").send(:photo_evidence_block)

    assert_not_includes block, "document on a screen"
  end

  private

  def build_service(question:, locale: "es", photo_value: @photo_value)
    Rag::PhotoQuestionAnswerService.new(
      question: question,
      photo_value: photo_value,
      session: @session,
      account: @account,
      user_id: users(:one).id,
      correlation_id: "photo:test",
      locale: locale
    )
  end
end
