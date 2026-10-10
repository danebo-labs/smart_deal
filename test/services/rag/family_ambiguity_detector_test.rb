# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/phase1_retrieval_fixture")

class Rag::FamilyAmbiguityDetectorTest < ActiveSupport::TestCase
  test "headings do not make one identifier ambiguous" do
    result = detect("¿A qué serie corresponde el LED SPM?", spm_chunks)

    assert_not result.ambiguous?
    assert_empty result.board_keys
    spm_chunks.each do |chunk|
      assert_nil Rag::PlateIdentity.designator(chunk)
      assert Rag::PlateIdentity.presentation_label(chunk).present?
    end
  end

  test "one identifier on three explicit plates with no plate named is ambiguous" do
    result = detect("¿A qué serie corresponde el LED SPM?", explicit_spm_chunks)

    assert result.ambiguous?
    assert_equal "SPM", result.identifier
    assert_equal [ "PLACA-TPR50", "PLACA-TWISTER", "PLACA-DELTA" ].sort, result.board_keys.sort
    assert_equal [ 1, 1, 1 ], result.chunks_by_board.values.map(&:size)
  end

  test "two explicit plates that share a section stay distinct" do
    chunks = [
      explicit_plate("PLACA-TWISTER", "SPM | SERIE DE PUERTAS", section: "SISTEL"),
      explicit_plate("PLACA-DELTA", "SPM | SERIE PUERTAS DE PISO", section: "SISTEL")
    ]

    result = detect("¿A qué serie corresponde el LED SPM?", chunks)

    assert result.ambiguous?
    assert_equal [ "PLACA-DELTA", "PLACA-TWISTER" ], result.board_keys.sort
    assert_equal [ "SISTEL" ], chunks.filter_map { |chunk| Rag::PlateIdentity.section_signal(chunk)&.value }.uniq
  end

  test "an identifier that passes the lexical equipment gate is still caught from explicit plates" do
    assert_match Rag::DeterministicIntent::EXPLICIT_EQUIPMENT_PATTERN, "¿Qué serie indica el LED DL2?"

    result = detect("¿Qué serie indica el LED DL2?", explicit_dl2_chunks)

    assert result.ambiguous?
    assert_equal "DL2", result.identifier
    assert_equal [ "PLACA-KDT", "PLACA-LEVEL" ].sort, result.board_keys.sort
  end

  test "the same identifier on heading-only chunks is not caught by the lexical gate's evidence" do
    result = detect("¿Qué serie indica el LED DL2?", dl2_chunks)

    assert_not result.ambiguous?
    assert_empty result.board_keys
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

  test "section identity does not vote as a plate" do
    chunks = [
      { content: "SPM | SERIE DE PUERTAS", metadata: { "section_identity" => "SISTEL" },
        chunk_sha256: "a", rank: 1 },
      { content: "SPM | SERIE PUERTAS CABINA - EXTERIORES",
        metadata: { "section_identity" => "CARLOS SILVA" }, chunk_sha256: "b", rank: 2 }
    ]

    result = detect("¿A qué serie corresponde el LED SPM?", chunks)

    assert_not result.ambiguous?
    assert_empty result.board_keys
    assert_equal [ "CARLOS SILVA", "SISTEL" ], chunks.filter_map { |chunk|
      Rag::PlateIdentity.section_signal(chunk)&.value
    }.sort
  end

  test "an empty evidence set is not ambiguous" do
    assert_not detect("¿A qué serie corresponde el LED SPM?", []).ambiguous?
  end

  test "a question without identifiers is not ambiguous" do
    assert_not detect("¿Qué información documenta el manual?", spm_chunks).ambiguous?
  end

  test "section headings of one manual do not make an identifier ambiguous" do
    chunks = Phase1RetrievalFixture.chunks

    result = detect(Rag::Phase1PinnedTurn::NATURAL_MESSAGE, chunks)

    assert_not result.ambiguous?
    assert_empty result.board_keys
    chunks.each do |chunk|
      assert_nil Rag::PlateIdentity.designator(chunk)
      assert_nil chunk[:metadata]["canonical_name"]
      assert_nil chunk[:metadata]["original_source_uri"]
    end
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

  # Synthetic board slots. The heading text in the source chunks is not a plate.
  def explicit_spm_chunks
    [
      explicit_plate("PLACA-TPR50", spm_chunks[0][:content], section: "CARLOS SILVA"),
      explicit_plate("PLACA-TWISTER", spm_chunks[1][:content], section: "SISTEL"),
      explicit_plate("PLACA-DELTA", spm_chunks[2][:content], section: "SISTEL")
    ]
  end

  def explicit_dl2_chunks
    [
      explicit_plate("PLACA-LEVEL", dl2_chunks[0][:content], section: "ALJO"),
      explicit_plate("PLACA-KDT", dl2_chunks[1][:content], section: "CARLOS SILVA")
    ]
  end

  def explicit_plate(designator, content, section:)
    {
      content: content,
      metadata: {
        "board_model" => designator,
        "section_identity" => section,
        "page_number" => 1
      },
      chunk_sha256: designator,
      rank: 1
    }
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
