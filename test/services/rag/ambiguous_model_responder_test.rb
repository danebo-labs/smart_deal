# frozen_string_literal: true

require "test_helper"

class Rag::AmbiguousModelResponderTest < ActiveSupport::TestCase
  PHASE1_PIN = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf"
  PHASE1_QUESTION = Rag::Phase1PinnedTurn::NATURAL_MESSAGE
  PHASE1_EVIDENCE = Rails.root.join(
    "tmp/phase1_pinned_turn/authorized_20261010/20261010T153620Z"
  )
  DOCUMENTARY_ANSWER = "En el documento seleccionado, la página 5 muestra la etiqueta «Seguridad Puerta nivel 2» entre las de los niveles 3 y 1. [1] No está confirmado para el equipo instalado."
  # Measured 2026-07-31 in tmp/pilot_gate/pilot_10q_v4_1.json: the board is
  # named unambiguously, yet the question reaches this responder because
  # "TWISTER TW" carries no digit for EXPLICIT_EQUIPMENT_PATTERN to catch.
  TWISTER_QUESTION =
    "Estoy con una Twister TW de Embarba eléctrica y sospecho de la serie de puertas. " \
    "¿Qué LED de la placa me lo confirma?"
  GENERIC_QUESTION = "¿Qué LED se enciende cuando falla?"

  FakeService = Struct.new(:chunks) do
    attr_reader :captured_kwargs, :retrieve_count

    def retrieve_chunks(*, **kwargs)
      @captured_kwargs = kwargs
      @retrieve_count = @retrieve_count.to_i + 1
      {
        chunks: chunks,
        retrieval_trace: {
          resolved_scope_s3_uris: [],
          applied_filter_s3_uris: [],
          force_entity_filter: false
        }
      }
    end
  end

  class FakeGenerator
    attr_reader :calls, :prompt

    def initialize(answer)
      @answer = answer
      @calls = 0
    end

    def query(prompt, **)
      @calls += 1
      @prompt = prompt
      @answer
    end
  end

  setup do
    @original_route_flag = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    @original_family_flag = ENV.fetch("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED", nil)
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
    ENV.delete("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED")
  end

  teardown do
    restore_flag("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", @original_route_flag)
    restore_flag("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED", @original_family_flag)
  end

  test "intent accepts a generic LED question and rejects a named model" do
    assert Rag::DeterministicIntent.ambiguous_hardware_query?(GENERIC_QUESTION)
    assert_not Rag::DeterministicIntent.ambiguous_hardware_query?("¿Qué indica DL27 en TOKIBAT?")
    assert_not Rag::DeterministicIntent.ambiguous_hardware_query?("¿Qué LED indica fallo en EM3000?")
  end

  # Hallazgo 8 of the pilot plan claims EDEL-K2 is the same open bug as
  # TWISTER TW. It is not: 4a66b01 (2026-07-28) added the optional letter to
  # EXPLICIT_EQUIPMENT_PATTERN, so EDEL-K2 has been routed past this responder
  # since that day. Only a board with no digit at all still reaches it.
  test "a hyphenated board with a digit no longer reads as ambiguous, one without a digit still does" do
    assert_not Rag::DeterministicIntent.ambiguous_hardware_query?(
      "En la EDEL-K2, ¿qué LED indica que los cerrojos están cerrados?"
    )
    assert Rag::DeterministicIntent.ambiguous_hardware_query?(TWISTER_QUESTION)
  end

  # CG-D19: one question in prose that names the boards. No chips.
  test "asks one prose question naming three evidence-backed boards when several are retrieved" do
    responder = build_responder(
      chunk("TOKIBAT", "DL27 TOKIBAT", page: 39),
      chunk("THYSSEN", "THYSSEN-E LED diagnostic", page: 93),
      chunk("ORONA", "ORONA MR08 LED status", page: 22),
      chunk("ALTIUS", "ALTIUS-D8 indicator", page: 7)
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_equal false, result[:model_invoked]
    assert_not result.key?(:quick_replies)
    assert_equal I18n.t(
      "rag.ambiguous_model_question", locale: :es,
      models: "TOKIBAT — DL27, THYSSEN — THYSSEN-E o ORONA — MR08"
    ), result[:answer]
    assert_not_includes result[:answer], "ALTIUS"
    assert_not_includes result[:answer], "\n"
    assert_equal [ 39, 93, 22 ], result[:citations].pluck(:page)
    assert_equal "choice", result.dig(:pending_question, "type")
    assert_equal [ "TOKIBAT — DL27", "THYSSEN — THYSSEN-E", "ORONA — MR08" ], result.dig(:pending_question, "options")
  end

  test "falls through when retrieval does not expose three distinct models" do
    responder = build_responder(
      chunk("TOKIBAT", "DL27 TOKIBAT", page: 39),
      chunk("THYSSEN", "THYSSEN-E LED diagnostic", page: 93)
    )

    assert_nil responder.execute
  end

  test "uses documented diagram headings when manufacturer metadata is absent" do
    responder = build_responder(
      heading_chunk("## S7 — DIAGRAM: CTA – M8PC (ELÉCTRICO Y HIDRÁULICO) / BORNAS CARRIL", 54),
      heading_chunk("## S4 — SAFETY SYSTEM: ARCA III — Diagrama de Series", 52),
      heading_chunk("## S7 — DIAGRAM: MAC 5000 — Esquema de Cadena", 55)
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_includes result[:answer], "CTA – M8PC (ELÉCTRICO Y HIDRÁULICO), ARCA III o MAC 5000"
  end

  test "does not fabricate a manufacturer from unrelated text in the chunk body" do
    responder = build_responder(
      heading_chunk("## EM 4000 V1\nCadena de seguridades ALTIUS conectada en serie.", 33),
      heading_chunk("## S4 — SAFETY SYSTEM: ARCA III — Diagrama de Series", 52),
      heading_chunk("## S7 — DIAGRAM: MAC 5000 — Esquema de Cadena", 55)
    )

    result = responder.execute

    assert_not_includes result[:answer], "ALTIUS — "
    assert_includes result[:answer], "EM 4000 V1"
  end

  test "the question is the same prose in English and never a numbered list" do
    responder = build_responder(
      chunk("TOKIBAT", "DL27 TOKIBAT", page: 39),
      chunk("THYSSEN", "THYSSEN-E LED diagnostic", page: 93),
      chunk("ORONA", "ORONA MR08 LED status", page: 22),
      response_locale: :en
    )

    result = responder.execute

    assert_not_includes result[:answer], "1."
    assert_includes result[:answer], "TOKIBAT — DL27, THYSSEN — THYSSEN-E or ORONA — MR08"
    assert_not result.key?(:quick_replies)
  end

  test "asks the retrieval layer for the contractual top_k" do
    responder = build_responder(
      chunk("TOKIBAT", "DL27 TOKIBAT", page: 39),
      chunk("THYSSEN", "THYSSEN-E LED diagnostic", page: 93),
      chunk("ORONA", "ORONA MR08 LED status", page: 22)
    )

    responder.execute

    assert_equal 20, responder.instance_variable_get(:@service).captured_kwargs[:number_of_results]
  end

  test "answers from the retrieval in hand when the question already names one board" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    generator = FakeGenerator.new("El LED SSEG confirma la serie de puertas. [1]")
    responder = build_responder(
      *twister_chunks,
      question: TWISTER_QUESTION,
      generator: generator
    )

    result = responder.execute

    assert_equal "structured_evidence_route", result[:generation_mode]
    assert_not result.key?(:quick_replies)
    assert_includes result[:answer], "SSEG"
    assert_equal 1, generator.calls
    assert_includes generator.prompt, "Twister TW"
    assert_includes generator.prompt, "# FIELD COMPANION"
    assert_not_includes generator.prompt, "TWISTER TW – ELECTRICO"
    assert_not_includes generator.prompt, "EDEL-K3"
    assert_not_includes generator.prompt, "APPLICABILITY_BLOCK"
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
  end

  test "an abstention from the route is still terminal, so the turn spends one retrieve" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    responder = build_responder(
      *twister_chunks,
      question: TWISTER_QUESTION,
      generator: FakeGenerator.new("")
    )

    result = responder.execute

    assert_not_nil result
    assert_equal "structured_evidence_route", result[:generation_mode]
    assert_equal :generation_failure, result.dig(:diagnostics, :outcome_reason)
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
  end

  test "the question names only the boards the technician named when there are more than one" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    responder = build_responder(
      *twister_chunks,
      question: "#{TWISTER_QUESTION} También tengo una Level Control 1B premontada.",
      generator: FakeGenerator.new("no debería generarse [1]")
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_includes result[:answer], "TWISTER TW – ELECTRICO - EMBARBA o LEVEL CONTROL 1B – ELECTRICO - PREMONTADA"
    assert_not_includes result[:answer], "EDEL-K3"
  end

  # The regression that stops the filter from disabling disambiguation whole:
  # a question that names no board must still get the three-way question.
  test "a question that names no board still gets the three-way question" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    generator = FakeGenerator.new("no debería generarse [1]")
    responder = build_responder(*twister_chunks, generator: generator)

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_includes result[:answer], "TWISTER TW – ELECTRICO - EMBARBA, LEVEL CONTROL 1B – ELECTRICO - PREMONTADA o EDEL-K3"
    assert_equal 0, generator.calls
  end

  # H-03: with the bug, BoardHeading.mentioned? treated "EDEL-K3" (retrieved)
  # as naming "EDEL-K2" (asked) because they share a six-character root before
  # the digit that actually distinguishes them. That made `named` a single
  # match, which answered directly — about the wrong board. Fixed, no board
  # is named and the technician still gets to choose among the three retrieved.
  test "a single retrieved sibling board does not answer a different sibling's question" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    generator = FakeGenerator.new("no debería generarse [1]")
    responder = build_responder(
      *twister_chunks,
      question: "En la EDEL-K2, ¿qué LED indica que los cerrojos están cerrados?",
      generator: generator
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_includes result[:answer], "EDEL-K3"
    assert_includes result[:answer], "TWISTER TW"
    assert_equal 0, generator.calls
  end

  test "with the live route flag off a named board still gets the question it gets today" do
    responder = build_responder(
      *twister_chunks,
      question: TWISTER_QUESTION,
      generator: FakeGenerator.new("no debería generarse [1]")
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert result[:answer].start_with?("La evidencia recuperada corresponde a varias placas: TWISTER TW – ELECTRICO - EMBARBA")
  end

  test "section headings of the selected manual are not plates and the retrieval is reused" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
    ENV["RAG_FAMILY_AMBIGUITY_GUARD_ENABLED"] = "false"
    generator = FakeGenerator.new("En el documento. [1]")
    responder = build_responder(
      *section_chunks,
      question: GENERIC_QUESTION,
      generator: generator,
      correlation_id: "phase1:6:query"
    )

    result = responder.execute

    assert_equal "structured_evidence_route", result[:generation_mode]
    assert_not_includes result[:answer], "varias placas"
    assert_equal 0, result[:citations].size
    assert_equal 1, generator.calls
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
    assert_equal "phase1:6:query", responder.instance_variable_get(:@service).captured_kwargs[:correlation_id]
    assert_equal "model_disambiguation", responder.instance_variable_get(:@service).captured_kwargs[:route_taken]
    section_chunks.each do |chunk|
      assert_nil Rag::PlateIdentity.declared_board_heading(chunk[:content])
      assert_nil Rag::PlateIdentity.board_key(chunk)
    end
  end

  test "the phase 1 chunks answer the selected document without creating identity" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
    ENV["RAG_FAMILY_AMBIGUITY_GUARD_ENABLED"] = "false"
    episode = {}
    generator = FakeGenerator.new(DOCUMENTARY_ANSWER)
    responder = build_responder(
      *phase1_chunks,
      question: PHASE1_QUESTION,
      raw_question: PHASE1_QUESTION,
      generator: generator,
      entity_s3_uris: [ PHASE1_PIN ],
      force_entity_filter: true,
      correlation_id: "phase1:6:query",
      episode: episode,
      equipment_identity: nil
    )

    result = responder.execute
    service = responder.instance_variable_get(:@service)

    assert_equal "structured_evidence_route", result[:generation_mode]
    assert_equal true, result[:model_invoked]
    assert_not_equal "unknown_identity_guidance", result[:publication_mode]
    assert_not_includes result[:answer], "varias placas"
    assert_includes result[:answer], "Seguridad Puerta nivel 2"
    assert_includes result[:answer], "[1]"
    assert_includes result[:answer], "No está confirmado"
    assert result[:citations].any?
    assert_includes generator.prompt, "Seguridad Puerta nivel 2"
    assert_includes generator.prompt, "ramas paralelas visuales"
    assert_includes generator.prompt, "The selected document is retrieval focus"
    assert_not_includes generator.prompt, "Those checks must not name a selector"
    assert_equal [ PHASE1_PIN ], service.captured_kwargs[:entity_s3_uris]
    assert_equal true, service.captured_kwargs[:force_entity_filter]
    assert_equal "phase1:6:query", service.captured_kwargs[:correlation_id]
    assert_equal "model_disambiguation", service.captured_kwargs[:route_taken]
    assert_equal 1, service.retrieve_count
    assert_equal({}, episode)
    assert_nil Rag::PlateIdentity.designator(phase1_chunks.first)
  end

  test "production route flags still reuse the phase 1 retrieval instead of the plate menu" do
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    ENV["RAG_FAMILY_AMBIGUITY_GUARD_ENABLED"] = "true"
    generator = FakeGenerator.new(DOCUMENTARY_ANSWER)
    responder = build_responder(
      *phase1_chunks,
      question: PHASE1_QUESTION,
      raw_question: PHASE1_QUESTION,
      generator: generator,
      entity_s3_uris: [ PHASE1_PIN ],
      force_entity_filter: true,
      correlation_id: "phase1:6:query",
      episode: {},
      equipment_identity: nil
    )

    result = responder.execute

    assert_equal "structured_evidence_route", result[:generation_mode]
    assert_not_includes result[:answer], "varias placas"
    assert result[:citations].any?
    assert_equal 1, generator.calls
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
    assert_not Rag::FamilyAmbiguityDetector.new.call(
      question_analysis: Rag::QueryEntities.analyze(PHASE1_QUESTION),
      chunks: phase1_chunks
    ).ambiguous?
  end

  test "explicit plate designators can still require clarification" do
    generator = FakeGenerator.new("no debería generarse [1]")
    responder = build_responder(
      plate_chunk("TWISTER"),
      plate_chunk("DELTA"),
      plate_chunk("EDEL"),
      generator: generator
    )

    result = responder.execute

    assert_equal "deterministic_model_disambiguation", result[:generation_mode]
    assert_equal 0, generator.calls
    assert_includes result[:answer], "TWISTER, DELTA o EDEL"
    assert_not_includes result[:answer], "Sección interna"
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
  end

  test "absent plate metadata is neither compatibility nor incompatibility" do
    chunk = {
      content: "S7 — DIAGRAMA\n\n## Alimentación principal y protecciones\n",
      metadata: {}
    }

    assert_nil Rag::PlateIdentity.designator(chunk)
    assert_nil Rag::PlateIdentity.board_key(chunk)
    assert_nil Rag::PlateIdentity.declared_board_heading(chunk[:content])
  end

  test "equipment manufacturer and plate designator stay different slots" do
    chunk = {
      content: "S7 — DIAGRAMA\n\n## Alimentación principal y protecciones\n",
      metadata: { "manufacturer" => "Controles", "board_model" => "CEA15" }
    }

    assert_equal "CEA15", Rag::PlateIdentity.designator(chunk)
    assert_equal "CEA15", Rag::PlateIdentity.board_key(chunk)
    assert_nil Rag::PlateIdentity.designator(
      content: chunk[:content], metadata: { "manufacturer" => "Controles" }
    )
  end

  test "a procedure on the selected document is withheld and does not search again" do
    generator = FakeGenerator.new("Puentea el contacto de la puerta del nivel 2. [1]")
    responder = build_responder(
      *phase1_chunks,
      question: PHASE1_QUESTION,
      raw_question: PHASE1_QUESTION,
      generator: generator,
      entity_s3_uris: [ PHASE1_PIN ],
      force_entity_filter: true,
      episode: {},
      equipment_identity: nil
    )

    result = responder.execute

    assert_equal :procedure_application, result[:applicability_violation]
    assert_empty result[:citations]
    assert_not_includes result[:answer], "Puentea"
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
  end

  test "uncited prose about the selected document abstains without another retrieve" do
    generator = FakeGenerator.new("La cadena queda definida. El orden es único.")
    responder = build_responder(
      *phase1_chunks,
      question: PHASE1_QUESTION,
      raw_question: PHASE1_QUESTION,
      generator: generator,
      entity_s3_uris: [ PHASE1_PIN ],
      force_entity_filter: true,
      episode: {},
      equipment_identity: nil
    )

    result = responder.execute

    assert_equal :insufficient_evidence, result.dig(:diagnostics, :outcome_reason)
    assert_not_includes result[:answer], "La cadena queda definida"
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
  end

  test "a blank generation abstains without another retrieve" do
    responder = build_responder(
      *phase1_chunks,
      question: PHASE1_QUESTION,
      raw_question: PHASE1_QUESTION,
      generator: FakeGenerator.new(""),
      entity_s3_uris: [ PHASE1_PIN ],
      force_entity_filter: true,
      episode: {},
      equipment_identity: nil
    )

    result = responder.execute

    assert_equal :generation_failure, result.dig(:diagnostics, :outcome_reason)
    assert_equal "structured_evidence_route", result[:generation_mode]
    assert_equal 1, responder.instance_variable_get(:@service).retrieve_count
  end

  private

  def restore_flag(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end

  def build_responder(*chunks, response_locale: :es, question: GENERIC_QUESTION, generator: nil,
                       entity_s3_uris: [], force_entity_filter: false, correlation_id: nil,
                       raw_question: nil, episode: nil, equipment_identity: :omit)
    Rag::AmbiguousModelResponder.new(
      question: question,
      account: accounts(:legacy),
      entity_s3_uris: entity_s3_uris,
      entity_sources: entity_s3_uris.any? ? [ "document" ] : [],
      force_entity_filter: force_entity_filter,
      response_locale: response_locale,
      rag_service: FakeService.new(chunks),
      generator: generator,
      correlation_id: correlation_id,
      raw_question: raw_question,
      episode: episode,
      equipment_identity: equipment_identity
    )
  end

  # The three labels the twister case actually retrieved (v4.1 artifact).
  def twister_chunks
    [
      board_chunk(
        "## S7 — DIAGRAM: TWISTER TW – ELECTRICO - EMBARBA",
        "El LED SSEG de la placa TW confirma la serie de puertas.",
        page: 89
      ),
      board_chunk(
        "## S7 — DIAGRAM: LEVEL CONTROL 1B – ELECTRICO - PREMONTADA",
        "Cadena de seguridades de la placa premontada.",
        page: 62
      ),
      board_chunk(
        "## EDEL-K3 Wiring Overview — Safety & Door Circuit Connections",
        "Conexionado de la cadena de puertas.",
        page: 25
      )
    ]
  end

  def board_chunk(heading, body, page:)
    {
      content: "#{heading}\n\n#{body}",
      location_uri: "s3://bucket/chunks/chunk_#{page - 2}.txt",
      original_source_uri: "s3://bucket/seguridades.pdf",
      chunk_sha256: "sha-#{page}",
      rank: page,
      metadata: {
        "canonical_name" => "SEGURIDADES 1.1-1.pdf",
        "original_source_uri" => "s3://bucket/seguridades.pdf",
        "page_number" => page
      }
    }
  end

  def chunk(manufacturer, content, page:)
    {
      content: content,
      location_uri: "s3://bucket/#{manufacturer.downcase}.txt",
      original_source_uri: "s3://bucket/#{manufacturer.downcase}.pdf",
      metadata: {
        "manufacturer" => manufacturer,
        "canonical_name" => "#{manufacturer} manual",
        "page_number" => page
      }
    }
  end

  def heading_chunk(heading, page)
    {
      content: heading,
      location_uri: "s3://bucket/chunk_p#{page}_1.txt",
      original_source_uri: "s3://bucket/seguridades.pdf",
      metadata: {}
    }
  end

  def section_chunks
    [
      "Alimentación principal y protecciones",
      "SECCIÓN CONEXIÓN SOBRE CABINA",
      "Componentes del Tablero (Tabla de Designaciones)"
    ].map.with_index do |heading, index|
      {
        content: "S7 — DIAGRAMA ELÉCTRICO\n\nTexto de la página.\n\n## #{heading}\n\nDetalle de la sección.\n",
        location_uri: "s3://bucket/section-#{index}.txt",
        original_source_uri: PHASE1_PIN,
        chunk_sha256: "section-#{index}",
        rank: index + 1,
        metadata: { "page_number" => index + 1, "original_source_uri" => PHASE1_PIN }
      }
    end
  end

  def plate_chunk(designator)
    {
      content: "Introducción del plano.\n\n## Sección interna\nEl LED indica estado.\n",
      location_uri: "s3://bucket/#{designator}.txt",
      original_source_uri: "s3://bucket/manual.pdf",
      chunk_sha256: designator,
      rank: 1,
      metadata: { "board_model" => designator, "page_number" => 1 }
    }
  end

  def phase1_chunks
    capture = JSON.parse(File.read(PHASE1_EVIDENCE.join("capture.json")))
    rows = capture["events"].find { |event| event["kind"] == "retrieval_results" }.fetch("rows")
    rows.each_with_index.map do |row, index|
      text = row["text"]
      content = text.is_a?(Hash) ? File.read(PHASE1_EVIDENCE.join(text["path"])) : text
      {
        content: content,
        location_uri: row["uri"],
        original_source_uri: PHASE1_PIN,
        chunk_sha256: Digest::SHA256.hexdigest(content),
        rank: index + 1,
        metadata: {
          "page_number" => row["page"].to_i,
          "original_source_uri" => PHASE1_PIN,
          "canonical_name" => row["document"]
        }
      }
    end
  end
end
