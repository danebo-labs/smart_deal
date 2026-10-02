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
      evidence_value: @photo_value,
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

  test "provenance segments do not depend on SHOW_RAG_SOURCES" do
    citations = [ { number: 1, title: "Manual", content: "chunk body that must not travel" } ]
    answer = "El procedimiento indica desconectar la alimentación [1]. Podés empezar revisando la alimentación."
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      { answer: answer, citations: citations, session_id: nil }
    end

    ENV["SHOW_RAG_SOURCES"] = "true"
    visible = build_service(question: "cómo sigo?").call
    ENV["SHOW_RAG_SOURCES"] = "false"
    hidden = build_service(question: "cómo sigo?").call

    assert_equal 1, visible[:citations].size
    assert_not visible[:citations].first.key?(:content)
    assert_equal [], hidden[:citations]
    assert_equal visible[:provenance_segments], hidden[:provenance_segments]
    assert_equal %w[MANUAL_FACT DANEBO_GUIDANCE], visible[:provenance_segments].pluck("band")
    assert_includes visible[:answer], "[1]"
    assert_not_includes hidden[:answer], "[1]"
    assert_not_includes visible[:provenance_segments].first["text"], "[1]"
  end

  test "photo question provenance uses the accepted snapshot and ignores the evidence projection" do
    photo = persist_observed_photo(account: @account, manufacturer: "KONE", component: "conjunto de resortes")
    foreign = persist_observed_photo(account: accounts(:climb), manufacturer: "OTIS-SECRET", component: "tablero secreto")
    snapshot = photo.visual_observation.deep_dup
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      { answer: "Fabricante KONE. En la foto: se observa SCHINDLER.", citations: [], session_id: nil }
    end

    result = build_service(
      question: "qué marca se ve?",
      photo_value: @photo_value.merge(manufacturer: "SCHINDLER", canonical_name: "tablero secreto"),
      field_photo_id: photo.id,
      accepted_observation: snapshot
    ).call

    assert_equal [ "VISUAL_OBSERVATION", "DANEBO_GUIDANCE" ], result[:provenance_segments].pluck("band")
    assert_includes result[:provenance_segments].first["text"], "KONE"
    assert result[:provenance_segments].none? { |segment| segment["band"] == "MANUAL_FACT" }

    ignored = build_service(
      question: "qué marca se ve?",
      photo_value: @photo_value.merge(manufacturer: "OTIS-SECRET"),
      field_photo_id: foreign.id
    ).call

    assert_equal [ "DANEBO_GUIDANCE", "DANEBO_GUIDANCE" ], ignored[:provenance_segments].pluck("band")
    assert_not_includes ignored[:provenance_segments].to_json, "OTIS-SECRET"
  end

  test "provenance keeps this turn's accepted snapshot when the row changes during generation" do
    photo = persist_observed_photo(account: @account, manufacturer: "KONE", component: "conjunto de resortes")
    snapshot = photo.visual_observation.deep_dup
    evidence = FieldPhotoObservation.reading_value(snapshot)
    replacement = snapshot.deep_dup
    replacement["manufacturer"] = "OTIS"
    captured = nil
    BedrockRagService.define_method(:query) do |_question, **kwargs|
      captured = kwargs
      photo.update!(visual_observation: replacement)
      { answer: "En la foto: se observa KONE.", citations: [], session_id: nil }
    end

    result = build_service(
      question: "qué marca se ve?",
      photo_value: evidence,
      field_photo_id: photo.id,
      accepted_observation: snapshot
    ).call

    assert_includes captured[:session_context], "Manufacturer: KONE"
    assert_not_includes captured[:session_context], "OTIS"
    assert_equal [ "VISUAL_OBSERVATION" ], result[:provenance_segments].pluck("band")
    assert_includes result[:provenance_segments].first["text"], "KONE"
    assert_not_includes result[:provenance_segments].to_json, "OTIS"
    assert_equal "OTIS", photo.reload.visual_observation["manufacturer"]
    assert_equal "KONE", snapshot["manufacturer"]
  end

  test "a supplied session snapshot stays in generation after the live episode changes" do
    captured = nil
    BedrockRagService.define_method(:query) do |_question, **kwargs|
      captured = kwargs
      { answer: "En la foto: se observa KONE.", citations: [], session_id: nil }
    end
    @session.update!(active_episode: {
      "episode_id" => "case-b",
      "goal" => { "text" => "no nivela", "correlation_id" => "case:b" },
      "facts" => { "manufacturer" => { "status" => "known", "value" => "OTIS", "source" => "user" } }
    })

    build_service(
      question: "qué marca se ve?",
      photo_value: @photo_value.merge(manufacturer: "KONE", canonical_name: "puerta"),
      session_context_snapshot: "Goal: puerta no cierra\nManufacturer: KONE (technician)",
      entity_s3_uris_snapshot: []
    ).call

    context = captured[:session_context].to_s
    assert_includes context, "puerta no cierra"
    assert_includes context, "Photo Evidence"
    assert_includes context, "Manufacturer: KONE"
    assert_not_includes context, "OTIS"
    assert_not_includes context, "no nivela"
    assert_equal [], captured[:entity_s3_uris]
  end

  test "a photo question without a stored observation does not invent a visual band" do
    BedrockRagService.define_method(:query) do |_question, **_kwargs|
      { answer: "En la foto: se observa KONE.", citations: [], session_id: nil }
    end

    result = build_service(question: "qué se ve?").call

    assert_equal [ "DANEBO_GUIDANCE" ], result[:provenance_segments].pluck("band")
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
    assert_nil captured_kwargs[:conv_session]
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |question, **kwargs| original_new.call(question, **kwargs) } if original_new
  end

  test "a post-photo retrieval question is the nested query and does not pass the session" do
    captured = nil
    original_new = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |question, **kwargs|
      captured = { question: question, kwargs: kwargs }
      original_new.call(question, **kwargs)
    end
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured[:bedrock] = { question: question, episode: kwargs[:episode] }
      { answer: "ok", citations: [], session_id: nil }
    end
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "Orona",
      needles: [ "PBCM-V3" ],
      facts: [ { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "photo:1" } ]
    )
    composed = "¿Qué ves y qué debería revisar primero? no nivela en planta 3 Orona PBCM-V3"

    service = build_service(
      question: "¿Qué ves y qué debería revisar primero?",
      photo_value: {
        canonical_name: "UNKNOWN", manufacturer: "UNKNOWN", model_visible: "UNKNOWN",
        condition: "GOOD", visible_codes: []
      },
      retrieval_question: composed,
      equipment_identity: identity
    )
    service.call

    assert_equal composed, captured[:question]
    assert_equal composed, captured[:bedrock][:question]
    assert_nil captured[:kwargs][:conv_session]
    assert_nil captured[:kwargs][:equipment_identity]
    assert_nil captured[:bedrock][:episode]
    assert_equal identity, service.equipment_identity
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

  test "a hidden target is stated before the answer and the condition line survives" do
    photo_value = {
      canonical_name: "Transformador trifásico con fusibles",
      manufacturer: "UNKNOWN",
      model_visible: "UNKNOWN",
      condition: "DEGRADED",
      visible_codes: [ "FEDEOSTRI 6N6", "000AC006T0T0" ],
      target_visible: false,
      missing_view_or_detail: "primer plano de las fijaciones de cables con sus resortes y de la placa"
    }

    block = build_service(
      question: "Cómo se ajustan los resortes de la fijación de cables ? es Fuji Yida",
      photo_value: photo_value
    ).send(:photo_evidence_block)

    assert_includes block, "Vision judged that this photo does not show what the question asks about"
    assert_includes block, "primer plano de las fijaciones de cables con sus resortes y de la placa"
    assert_includes block, "Say that first"
    assert_includes block, "Say that mismatch first"
    assert_includes block, "Condition: DEGRADED"
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

  test "an unrelated accepted observation contributes an empty retrieval anchor" do
    captured = nil
    BedrockRagService.define_method(:query) do |question, **kwargs|
      captured = { question: question, kwargs: kwargs }
      { answer: "ok", citations: [], session_id: nil }
    end

    build_service(
      question: "Que equipo es?",
      photo_value: @photo_value.merge(relevance_to_goal: "unrelated")
    ).call

    assert_equal "Que equipo es?", captured[:question]
    assert_not_includes captured[:question], "GECB"
    assert_includes captured[:kwargs][:session_context], "Photo Evidence"
    assert_includes captured[:kwargs][:session_context], "GECB"
  end

  def build_service(question:, locale: "es", photo_value: @photo_value, field_photo_id: nil, accepted_observation: nil, session_context_snapshot: nil, entity_s3_uris_snapshot: nil, retrieval_question: nil, equipment_identity: nil)
    Rag::PhotoQuestionAnswerService.new(
      question: question,
      evidence_value: photo_value,
      session: @session,
      account: @account,
      user_id: users(:one).id,
      correlation_id: "photo:test",
      locale: locale,
      field_photo_id: field_photo_id,
      accepted_observation: accepted_observation,
      session_context_snapshot: session_context_snapshot,
      entity_s3_uris_snapshot: entity_s3_uris_snapshot,
      retrieval_question: retrieval_question,
      equipment_identity: equipment_identity
    )
  end

  def persist_observed_photo(account:, manufacturer:, component:)
    sha = SecureRandom.hex(32)
    photo = FieldPhoto.create!(
      account: account,
      sha256: sha,
      s3_key_original: "field_photos/#{account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg",
      byte_size: 8
    )
    parsed = {
      "canonical_component" => component,
      "manufacturer" => manufacturer,
      "model" => "MX20",
      "subsystem" => "DOOR_OPERATOR",
      "condition" => "DEGRADED",
      "visible_text" => [ "708A" ],
      "target_visible" => true,
      "relevance_to_goal" => "relevant"
    }
    FieldPhotoObservation.persist!(
      photo,
      FieldPhotoObservation.from_analysis(
        parsed: parsed,
        model_id: "claude-sonnet-5-5",
        target_visible: parsed["target_visible"],
        relevance_to_goal: parsed["relevance_to_goal"]
      )
    )
    photo
  end
end
