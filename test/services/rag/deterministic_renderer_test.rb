# frozen_string_literal: true

require "test_helper"

class Rag::DeterministicRendererTest < ActiveSupport::TestCase
  URIS = [ "s3://kb/uploads/2026-06-10/manual.pdf" ].freeze

  FT_CHUNK = <<~CHUNK
    [DOCUMENT: manual.pdf]
    Narrativa de la sección.

    FIELD_RECORD:
    RECORD_ID: FR-TEST000000000001
    SOURCE_SECTION_OR_PAGE: Prueba de bocina
    RECORD_TYPE: FUNCTIONAL_TEST
    ACTION: Pulse el botón de la bocina
    EXPECTED_RESULT: Sonará la bocina
    EVIDENCE: Resultado: Sonará la bocina
    END_FIELD_RECORD

    FIELD_RECORD:
    RECORD_ID: FR-TEST000000000002
    SOURCE_SECTION_OR_PAGE: Prueba de bocina
    RECORD_TYPE: FUNCTIONAL_TEST
    ACTION: Pulse el botón de la bocina otra vez
    EXPECTED_RESULT: DATA_NOT_AVAILABLE
    EVIDENCE: sin resultado documentado
    END_FIELD_RECORD

    FIELD_RECORD:
    RECORD_ID: FR-TEST000000000003
    SOURCE_SECTION_OR_PAGE: Operaciones en la Plataforma
    RECORD_TYPE: FUNCTIONAL_TEST
    ACTION: Mover joystick para operar
    EXPECTED_RESULT: La máquina opera
    EVIDENCE: operación normal
    END_FIELD_RECORD

    FIELD_RECORD:
    RECORD_ID: FR-TEST000000000004
    SOURCE_SECTION_OR_PAGE: (continuación de página anterior)
    RECORD_TYPE: FUNCTIONAL_TEST
    ACTION: Presione el interruptor según flecha derecha
    EXPECTED_RESULT: El volante gira a la derecha
    EVIDENCE: el volante debe girarse a la derecha
    END_FIELD_RECORD
  CHUNK

  SW_CHUNK = <<~CHUNK
    [DOCUMENT: manual.pdf]

    FIELD_RECORD:
    RECORD_ID: FR-TEST00000000000A
    SOURCE_SECTION_OR_PAGE: Velocidad limitada
    RECORD_TYPE: STOP_WORK_CONDITION
    ACTION: Verificar velocidad con plataforma elevada
    EXPECTED_RESULT: No supera 20 cm/s
    STOP_WORK_TRIGGER: Velocidad supera 20 cm/s con plataforma elevada
    STOP_WORK_REQUIRED_ACTION: Marque la máquina inmediatamente y deje de funcionar
    EVIDENCE: marque la máquina y deje de funcionar
    END_FIELD_RECORD

    FIELD_RECORD:
    RECORD_ID: FR-TEST00000000000B
    SOURCE_SECTION_OR_PAGE: Comprobación previa
    RECORD_TYPE: INSPECTION_CHECK
    ACTION: Asegúrese de que el operador no experimente mareos antes de operar
    EXPECTED_RESULT: DATA_NOT_AVAILABLE
    EVIDENCE: no experimente mareos
    END_FIELD_RECORD

    FIELD_RECORD:
    RECORD_ID: FR-TEST00000000000C
    SOURCE_SECTION_OR_PAGE: Comprobación previa
    RECORD_TYPE: SAFETY_WARNING
    ACTION: Asegúrese de que personal no autorizado no interfiera con el equipo
    EXPECTED_RESULT: DATA_NOT_AVAILABLE
    EVIDENCE: personal no autorizado
    END_FIELD_RECORD
  CHUNK

  class FakeRagService
    attr_reader :calls

    def initialize(chunks)
      @chunks = chunks
      @calls = []
    end

    def retrieve_chunks(question, **kwargs)
      @calls << kwargs.merge(question: question)
      {
        chunks: @chunks.each_with_index.map do |text, index|
          {
            rank: index + 1, content: text, score: 0.9,
            original_source_uri: URIS.first,
            location_uri: "s3://kb/bulk_chunks/x/chunk_#{index}.txt",
            metadata: { "canonical_name" => "Manual Tijera" },
            chunk_sha256: Digest::SHA256.hexdigest(text)
          }
        end,
        retrieval_trace: { resolved_scope_s3_uris: URIS, applied_filter_s3_uris: URIS,
                           force_entity_filter: true }
      }
    end
  end

  Q_FT = "¿Qué pruebas funcionales previas al uso indica el manual y qué resultado esperado tiene cada una?"
  Q_SW = "Antes de operar este equipo, ¿qué comprobaciones debo realizar y en qué condiciones debo detener el trabajo?"

  def build(question, chunks)
    service = FakeRagService.new(chunks)
    renderer = Rag::DeterministicRenderer.build(
      question: question, entity_s3_uris: URIS, entity_sources: [ "document" ],
      force_entity_filter: true, response_locale: "es", rag_service: service
    )
    [ renderer, service ]
  end

  # ── intent narrowness ────────────────────────────────────────────────────────

  test "narrow intents match the four benchmark phrasings and nothing broader" do
    assert Rag::DeterministicIntent.exhaustive_functional_test_query?(Q_FT)
    assert Rag::DeterministicIntent.exhaustive_functional_test_query?(
      "Después de esas inspecciones, ¿qué pruebas funcionales debo ejecutar y qué resultados debo obtener?"
    )
    assert Rag::DeterministicIntent.stop_work_checklist_query?(Q_SW)
    assert Rag::DeterministicIntent.stop_work_checklist_query?(
      "Antes de operarlo, ¿qué comprobaciones debo realizar y cuándo debo detener el trabajo?"
    )

    # Failure/repair stays generative (plan: not all safety_critical_query?).
    assert_not Rag::DeterministicIntent.exhaustive_functional_test_query?(
      "Si alguna prueba funcional falla, ¿qué acciones indica expresamente el manual y quién puede reparar la máquina?"
    )
    assert_not Rag::DeterministicIntent.stop_work_checklist_query?(
      "¿Qué condiciones del lugar de trabajo debo inspeccionar antes de mover y operar esta plataforma?"
    )
  end

  test "no deterministic path without forced pinned scope" do
    assert_nil Rag::DeterministicRenderer.build(
      question: Q_FT, entity_s3_uris: [], entity_sources: [],
      force_entity_filter: false, response_locale: "es"
    )
    assert_nil Rag::DeterministicRenderer.build(
      question: Q_FT, entity_s3_uris: URIS, entity_sources: [ "document" ],
      force_entity_filter: false, response_locale: "es"
    )
  end

  # ── functional test renderer ────────────────────────────────────────────────

  test "renders only test-section records, one retrieve, no model" do
    renderer, service = build(Q_FT, [ FT_CHUNK ])
    result = renderer.execute

    assert_equal 1, service.calls.size, "exactly one Retrieve call"
    assert_equal Rag::DeterministicRenderer::FULL_SCOPE_CANDIDATES, service.calls.first[:number_of_results]
    assert service.calls.first[:force_entity_filter]
    assert_equal "deterministic_functional_tests", result[:generation_mode]
    assert_equal false, result[:model_invoked]
    assert_equal "ok", result[:deterministic_validation]

    # Operation-heading record excluded; test + continuation records included.
    assert_equal %w[FR-TEST000000000001 FR-TEST000000000002 FR-TEST000000000004],
                 result[:rendered_record_ids]
    assert_includes result[:parsed_record_ids], "FR-TEST000000000003"

    blocks = result[:answer].split(/\n\n/)
    assert_equal 3, blocks.size
    blocks.each do |block|
      lines = block.lines.map(&:strip)
      assert_equal 3, lines.size
      assert_match(/\APrueba: /, lines[0])
      assert_match(/\AAcción: /, lines[1])
      assert_match(/\AResultado esperado: /, lines[2])
    end
    assert_includes result[:answer], "Prueba de bocina (2)"
    assert_includes result[:answer], "Resultado esperado: DATA_NOT_AVAILABLE"
    assert_no_match(/FR-TEST/, result[:answer])
  end

  test "fails safe with DATA_NOT_AVAILABLE when the ledger is invalid" do
    truncated = FT_CHUNK.sub("END_FIELD_RECORD\n\nFIELD_RECORD:\nRECORD_ID: FR-TEST000000000004", "FIELD_RECORD:\nRECORD_ID: FR-TEST000000000004")
    renderer, = build(Q_FT, [ truncated ])
    result = renderer.execute

    assert_match(/\ADATA_NOT_AVAILABLE/, result[:answer])
    assert_not_equal "ok", result[:deterministic_validation]
    assert_empty result[:rendered_record_ids]
  end

  test "fails safe when no records are retrieved" do
    renderer, = build(Q_FT, [ "[DOCUMENT: manual.pdf]\nSolo narrativa." ])
    result = renderer.execute

    assert_match(/\ADATA_NOT_AVAILABLE/, result[:answer])
    assert_equal "empty_ledger", result[:deterministic_validation]
  end

  # ── stop-work renderer ──────────────────────────────────────────────────────

  test "stop-work renders only complete pairs as mandatory and keeps precautions apart" do
    renderer, service = build(Q_SW, [ SW_CHUNK ])
    result = renderer.execute

    assert_equal 1, service.calls.size
    assert_equal "deterministic_stop_work", result[:generation_mode]
    assert_equal false, result[:model_invoked]

    answer = result[:answer]
    mandatory_section = answer.split("Detención obligatoria con evidencia explícita").last
    assert_includes mandatory_section, "Disparador: Velocidad supera 20 cm/s con plataforma elevada"
    assert_includes mandatory_section, "Acción obligatoria: Marque la máquina inmediatamente y deje de funcionar"
    assert_not_includes mandatory_section, "mareos"
    assert_not_includes mandatory_section, "personal no autorizado"

    precautions_section = answer[/Precauciones e inspecciones(.*)Detención obligatoria/m, 1]
    assert_includes precautions_section, "mareos"
    assert_includes precautions_section, "personal no autorizado"
  end

  test "stop-work fails safe when there are no stop-work records" do
    only_precautions = SW_CHUNK.split("FIELD_RECORD:\nRECORD_ID: FR-TEST00000000000B").last
    renderer, = build(Q_SW, [ "FIELD_RECORD:\nRECORD_ID: FR-TEST00000000000B#{only_precautions}" ])
    result = renderer.execute

    assert_match(/\ADATA_NOT_AVAILABLE/, result[:answer])
    assert_equal "no_applicable_records", result[:deterministic_validation]
  end

  # ── orchestration ───────────────────────────────────────────────────────────

  test "orchestrator routes deterministic intents and keeps other queries generative" do
    fake = FakeRagService.new([])
    deterministic = Rag::DeterministicRenderer.build(
      question: Q_FT, entity_s3_uris: URIS, entity_sources: [ "document" ],
      force_entity_filter: true, rag_service: fake
    )
    assert_instance_of Rag::FunctionalTestRenderer, deterministic

    generative = Rag::DeterministicRenderer.build(
      question: "¿Cuál es el propósito de este equipo y cuáles son sus cinco partes principales?",
      entity_s3_uris: URIS, entity_sources: [ "document" ], force_entity_filter: true,
      rag_service: fake
    )
    assert_nil generative
  end

  test "deterministic result carries citations only from contributing chunks" do
    renderer, = build(Q_FT, [ FT_CHUNK, "[DOCUMENT: manual.pdf]\nNarrativa sin records." ])
    result = renderer.execute

    assert_equal 1, result[:retrieved_citations].size
    assert_equal 1, result[:citations].size
    assert_equal URIS.first, result[:doc_refs].first["source_uri"]
    assert_equal 2, result[:retrieved_chunk_sha256s].size
  end
end
