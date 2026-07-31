# frozen_string_literal: true

require "test_helper"

class Rag::FamilyAmbiguityDetectorTest < ActiveSupport::TestCase
  test "one identifier documented on three boards with no board named is ambiguous" do
    result = detect("¿A qué serie corresponde el LED SPM?", spm_chunks)

    assert result.ambiguous?
    assert_equal "SPM", result.identifier
    assert_equal [ "CARLOS SILVA TPR50", "TWISTER TW - INAPELSA", "DELTA +" ].sort,
                 result.board_keys.sort
    assert_equal [ 1, 1, 1 ], result.chunks_by_board.values.map(&:size)
  end

  test "an identifier that passes the lexical equipment gate is still caught by the evidence" do
    # "DL2" reads as explicitly scoped equipment, so no lexical gate can protect
    # the technician here — only the retrieved evidence can.
    assert_match Rag::DeterministicIntent::EXPLICIT_EQUIPMENT_PATTERN, "¿Qué serie indica el LED DL2?"

    result = detect("¿Qué serie indica el LED DL2?", dl2_chunks)

    assert result.ambiguous?
    assert_equal "DL2", result.identifier
    assert_equal [ "LEVEL CONTROL 1B – ELECTRICO - PREMONTADA", "KDT 11" ].sort,
                 result.board_keys.sort
  end

  test "a question that names its board is never ambiguous" do
    result = detect("En la placa ARCA II, ¿qué serie indica el LED P32?", arca_chunks)

    assert_not result.ambiguous?
    assert_nil result.identifier
    assert_empty result.board_keys
  end

  test "a comparative question that names two boards is not ambiguous" do
    result = detect(
      "En la placa ARCA básica, ¿qué serie indica el LED P32? ¿Significa lo mismo en ARCA III?",
      arca_chunks
    )

    assert_not result.ambiguous?
  end

  test "a table question scoped to one board is not ambiguous even with a sibling board retrieved" do
    chunks = [
      chunk(
        "## Tabla de LEDs de la cadena serie — MICONIC LX\nT1 | SERIE SEGURIDADES PRINCIPALES",
        page: 81,
        section_identity: "SCHINDLER"
      ),
      chunk(
        "## Indicadores LED de Serie — Tabla de la Placa\nT1 | SERIE PUERTAS EXTERIORES",
        page: 84,
        section_identity: "SCHINDLER"
      )
    ]

    result = detect(
      "En la placa MICONIC LX de Schindler, lista los LEDs T1 a T5 y la serie que indica cada uno.",
      chunks
    )

    assert_not result.ambiguous?
  end

  test "an identifier documented on a single board is not ambiguous" do
    chunks = [
      chunk("## CARLOS SILVA TPR50 — Cadena de Seguridades\nSPM | SERIE PUERTAS CABINA - EXTERIORES",
            page: 9, section_identity: "CARLOS SILVA"),
      chunk("## TWISTER TW - INAPELSA — Diagrama de conexiones\nSSEG | SERIE DE SEGURIDADES",
            page: 88, section_identity: "SISTEL")
    ]

    result = detect("¿A qué serie corresponde el LED SPM?", chunks)

    assert_not result.ambiguous?
  end

  test "chunks without a heading or a section identity never vote for ambiguity" do
    chunks = [
      { content: "SPM | SERIE DE PUERTAS", metadata: { "page_number" => 88 }, chunk_sha256: "a", rank: 1 },
      { content: "SPM | SERIE PUERTAS DE PISO", metadata: {}, chunk_sha256: "b", rank: 2 }
    ]

    result = detect("¿A qué serie corresponde el LED SPM?", chunks)

    assert_not result.ambiguous?
  end

  test "a chunk falls back to its section identity when it declares no heading" do
    chunks = [
      { content: "SPM | SERIE DE PUERTAS", metadata: { "section_identity" => "SISTEL" },
        chunk_sha256: "a", rank: 1 },
      { content: "SPM | SERIE PUERTAS CABINA - EXTERIORES",
        metadata: { "section_identity" => "CARLOS SILVA" }, chunk_sha256: "b", rank: 2 }
    ]

    result = detect("¿A qué serie corresponde el LED SPM?", chunks)

    assert result.ambiguous?
    assert_equal %w[CARLOS\ SILVA SISTEL], result.board_keys.sort
  end

  test "an empty evidence set is not ambiguous" do
    assert_not detect("¿A qué serie corresponde el LED SPM?", []).ambiguous?
  end

  test "a question without identifiers is not ambiguous" do
    assert_not detect("¿Qué información documenta el manual?", spm_chunks).ambiguous?
  end

  private

  def detect(question, chunks)
    Rag::FamilyAmbiguityDetector.new.call(
      question_analysis: Rag::QueryEntities.analyze(question),
      chunks: chunks
    )
  end

  def spm_chunks
    [
      chunk(
        "## S7 — DIAGRAM: CARLOS SILVA TPR50 — Cadena de Seguridades\nSPM | SERIE PUERTAS CABINA - EXTERIORES",
        page: 9,
        section_identity: "CARLOS SILVA"
      ),
      chunk(
        "## S7 — DIAGRAM: TWISTER TW - INAPELSA — Diagrama de conexiones\nSPM | SERIE DE PUERTAS",
        page: 88,
        section_identity: "SISTEL"
      ),
      chunk(
        "## DELTA + — Diagrama de Cadena de Seguridad\nSPM | SERIE PUERTAS DE PISO",
        page: 91,
        section_identity: "SISTEL"
      )
    ]
  end

  def dl2_chunks
    [
      chunk(
        "## LEVEL CONTROL 1B – ELECTRICO - PREMONTADA\nDL2 | SERIE CERROJOS CERRADA",
        page: 3,
        section_identity: "ALJO"
      ),
      chunk(
        "## KDT 11 — Diagrama de Series\nDL2 | SERIE PUERTAS EXTERIORES - CABINA",
        page: 13,
        section_identity: "CARLOS SILVA"
      )
    ]
  end

  def arca_chunks
    [
      chunk("## Diagrama de Cadena de Seguridades — Placa ARCA\nP32 | SERIE CERROJOS CABINA -EXTERIORES",
            page: 61, section_identity: "ORONA"),
      chunk("## ARCA BASICO — Tabla de Series\nP32 | SERIE CERROJOS CABINA - EXTERIORES",
            page: 62, section_identity: "ORONA"),
      chunk("## S7 — DIAGRAM: ARCA II Safety Chain & Connector Layout\nP32 | SERIE CERROJOS EXTERIORES - CABINA",
            page: 63, section_identity: "ORONA"),
      chunk("## S4 — SAFETY SYSTEM: Diagrama de cadena de seguridades ARCA III\nP32 | SERIE SEGURIDADES PRINCIPALES",
            page: 64, section_identity: "ORONA")
    ]
  end

  def chunk(content, page:, section_identity:)
    {
      content: content,
      metadata: {
        "canonical_name" => "SEGURIDADES 1.1-1.pdf",
        "page_number" => page,
        "section_identity" => section_identity
      },
      location_uri: "s3://test-bucket/chunks/chunk_p#{page}.txt",
      chunk_sha256: "sha-#{page}",
      rank: page
    }
  end
end
