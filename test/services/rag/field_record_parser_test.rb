# frozen_string_literal: true

require "test_helper"

class Rag::FieldRecordParserTest < ActiveSupport::TestCase
  VALID_BLOCK = <<~RECORD
    FIELD_RECORD:
    RECORD_ID: FR-AAAA000011112222
    SOURCE_SECTION_OR_PAGE: Prueba de bocina
    RECORD_TYPE: FUNCTIONAL_TEST
    ACTION: Pulse el botón de la bocina
    EXPECTED_RESULT: Sonará la bocina
    EVIDENCE: Resultado: Sonará la bocina
    END_FIELD_RECORD
  RECORD

  STOP_WORK_BLOCK = <<~RECORD
    FIELD_RECORD:
    RECORD_ID: FR-BBBB000011112222
    SOURCE_SECTION_OR_PAGE: Velocidad limitada
    RECORD_TYPE: STOP_WORK_CONDITION
    ACTION: Verificar velocidad con plataforma elevada
    EXPECTED_RESULT: No supera 20 cm/s
    STOP_WORK_TRIGGER: Velocidad supera 20 cm/s con plataforma elevada
    STOP_WORK_REQUIRED_ACTION: Marque la máquina inmediatamente y deje de funcionar
    EVIDENCE: marque la máquina inmediatamente y deje de funcionar
    END_FIELD_RECORD
  RECORD

  test "parses a valid block with all fields" do
    result = Rag::FieldRecordParser.parse_text(VALID_BLOCK, uri: "s3://b/c.txt", rank: 3, chunk_sha256: "h1")

    assert_empty result[:invalid]
    record = result[:records].sole
    assert_equal "FR-AAAA000011112222", record.record_id
    assert_equal "FUNCTIONAL_TEST", record.type
    assert_equal "Prueba de bocina", record.source
    assert_equal "Pulse el botón de la bocina", record.action
    assert_equal "Sonará la bocina", record.expected_result
    assert_equal "Resultado: Sonará la bocina", record.evidence
    assert_equal 3, record.rank
    assert_equal "s3://b/c.txt", record.uri
  end

  test "parses stop-work pair" do
    record = Rag::FieldRecordParser.parse_text(STOP_WORK_BLOCK)[:records].sole

    assert record.stop_work?
    assert_equal "Velocidad supera 20 cm/s con plataforma elevada", record.stop_trigger
    assert_equal "Marque la máquina inmediatamente y deje de funcionar", record.stop_action
  end

  test "narrative text outside blocks never creates records" do
    text = <<~TEXT
      El técnico debe detener el trabajo (stop) y marcar la máquina si observa daños.
      STOP_WORK_TRIGGER: esto no está dentro de un bloque
      #{VALID_BLOCK}
    TEXT

    result = Rag::FieldRecordParser.parse_text(text)

    assert_equal 1, result[:records].size
    assert_empty result[:invalid]
  end

  test "missing END delimiter invalidates the block" do
    truncated = VALID_BLOCK.sub("END_FIELD_RECORD", "").strip
    result = Rag::FieldRecordParser.parse_text(truncated)

    assert_empty result[:records]
    assert_match(/EOF before END/, result[:invalid].sole.reason)
  end

  test "new FIELD_RECORD before END invalidates the open block" do
    text = VALID_BLOCK.sub("END_FIELD_RECORD", "") + STOP_WORK_BLOCK
    result = Rag::FieldRecordParser.parse_text(text)

    assert_equal 1, result[:records].size
    assert_equal "FR-BBBB000011112222", result[:records].sole.record_id
    assert_match(/new FIELD_RECORD before END/, result[:invalid].sole.reason)
  end

  test "duplicate label invalidates the record" do
    text = VALID_BLOCK.sub("EVIDENCE:", "ACTION: otra accion\nEVIDENCE:")
    result = Rag::FieldRecordParser.parse_text(text)

    assert_empty result[:records]
    assert_match(/duplicate label ACTION/, result[:invalid].sole.reason)
  end

  test "unknown label invalidates the record" do
    text = VALID_BLOCK.sub("EVIDENCE:", "FOO: bar\nEVIDENCE:")
    result = Rag::FieldRecordParser.parse_text(text)

    assert_empty result[:records]
    assert_match(/unknown or malformed/, result[:invalid].sole.reason)
  end

  test "missing mandatory key invalidates the record" do
    text = VALID_BLOCK.sub(/^EXPECTED_RESULT: .*\n/, "")
    result = Rag::FieldRecordParser.parse_text(text)

    assert_empty result[:records]
    assert_match(/missing EXPECTED_RESULT/, result[:invalid].sole.reason)
  end

  test "incomplete stop-work pair invalidates the record" do
    text = STOP_WORK_BLOCK.sub(/^STOP_WORK_REQUIRED_ACTION: .*\n/, "")
    result = Rag::FieldRecordParser.parse_text(text)

    assert_empty result[:records]
    assert_match(/incomplete stop-work pair/, result[:invalid].sole.reason)
  end

  test "physical duplicates dedupe keeping provenance" do
    ledger = Rag::FieldRecordParser.parse_chunks([
      { content: VALID_BLOCK, rank: 1, original_source_uri: "s3://b/m.pdf", chunk_sha256: "h1" },
      { content: VALID_BLOCK, rank: 7, original_source_uri: "s3://b/m.pdf", chunk_sha256: "h2" }
    ])

    assert ledger.valid?
    record = ledger.records.sole
    assert_equal %w[h1 h2], record.provenances.pluck(:chunk_sha256)
  end

  test "same RECORD_ID with different content invalidates the ledger" do
    conflicting = VALID_BLOCK.sub("Sonará la bocina", "No sonará nada")
    ledger = Rag::FieldRecordParser.parse_chunks([
      { content: VALID_BLOCK, rank: 1, chunk_sha256: "h1" },
      { content: conflicting, rank: 2, chunk_sha256: "h2" }
    ])

    assert_not ledger.valid?
    assert_equal [ "FR-AAAA000011112222" ], ledger.conflicting_ids
    assert_empty ledger.records.select { |r| r.record_id == "FR-AAAA000011112222" }
  end

  test "renderer output round-trips through the parser" do
    service = BatchResultsParserService.new(s3_service: Object.new)
    rendered = service.send(
      :render_field_record,
      {
        "k" => "STOP_WORK_CONDITION",
        "h" => "Velocidad limitada",
        "a" => "Verificar velocidad",
        "r" => "No supera 20 cm/s",
        "ev" => "marque la máquina y deje de funcionar",
        "sw" => [ "Velocidad supera 20 cm/s", "marque la máquina y deje de funcionar" ],
        "x" => "criteria=20 cm/s",
        "ra" => "técnico de servicio calificado",
        "u" => "LOW visibilidad parcial"
      },
      page: 11
    )

    result = Rag::FieldRecordParser.parse_text(rendered)

    assert_empty result[:invalid]
    record = result[:records].sole
    assert record.stop_work?
    assert_equal "criteria=20 cm/s", record.details
    assert_equal "técnico de servicio calificado", record.repair_authority
    assert_equal "LOW visibilidad parcial", record.uncertainty
    assert record.record_id.start_with?("FR-")
  end

  # ---------------------------------------------------------------------------
  # B.2 — context-distinct stop-work records survive in the ledger
  # ---------------------------------------------------------------------------

  GROUND_STOP_BLOCK = <<~RECORD
    FIELD_RECORD:
    RECORD_ID: FR-GROUND0000000001
    SOURCE_SECTION_OR_PAGE: 2.1.1 Controles de tierra — Parada de emergencia
    RECORD_TYPE: STOP_WORK_CONDITION
    ACTION: Presione el botón de parada de emergencia a posición apagado
    EXPECTED_RESULT: Se detienen todas las funciones
    STOP_WORK_TRIGGER: emergencia desde controles de tierra
    STOP_WORK_REQUIRED_ACTION: presionar botón rojo a posición apagado
    EVIDENCE: para detener todas las funciones desde controles de tierra
    END_FIELD_RECORD
  RECORD

  PLATFORM_STOP_BLOCK = <<~RECORD
    FIELD_RECORD:
    RECORD_ID: FR-PLATFORM000000001
    SOURCE_SECTION_OR_PAGE: Control de plataforma — Parada de emergencia
    RECORD_TYPE: STOP_WORK_CONDITION
    ACTION: Presione el botón de parada de emergencia a posición apagado
    EXPECTED_RESULT: Se detienen todas las funciones
    STOP_WORK_TRIGGER: emergencia desde control de plataforma
    STOP_WORK_REQUIRED_ACTION: presionar botón rojo a posición apagado
    EVIDENCE: para detener todas las funciones desde control de plataforma
    END_FIELD_RECORD
  RECORD

  test "ground-control emergency-stop record survives as a distinct record" do
    result = Rag::FieldRecordParser.parse_text(GROUND_STOP_BLOCK)

    assert_empty result[:invalid]
    record = result[:records].sole
    assert record.stop_work?
    assert_equal "FR-GROUND0000000001", record.record_id
    assert_includes record.source, "Controles de tierra"
    assert_equal "emergencia desde controles de tierra", record.stop_trigger
  end

  test "platform-control emergency-stop record survives as a distinct record" do
    result = Rag::FieldRecordParser.parse_text(PLATFORM_STOP_BLOCK)

    assert_empty result[:invalid]
    record = result[:records].sole
    assert record.stop_work?
    assert_equal "FR-PLATFORM000000001", record.record_id
    assert_includes record.source, "Control de plataforma"
    assert_equal "emergencia desde control de plataforma", record.stop_trigger
  end

  test "ground and platform stop-work records survive together as distinct records in the ledger" do
    combined_text = GROUND_STOP_BLOCK + PLATFORM_STOP_BLOCK

    ledger = Rag::FieldRecordParser.parse_chunks([
      { content: combined_text, rank: 1, chunk_sha256: "sha_combined" }
    ])

    assert ledger.valid?,
      "ledger must be valid; conflicting IDs: #{ledger.conflicting_ids.inspect}"
    stop_records = ledger.records.select(&:stop_work?)
    assert_equal 2, stop_records.size,
      "both ground-control and platform-control stop-work records must appear"
    record_ids = stop_records.map(&:record_id)
    assert_includes record_ids, "FR-GROUND0000000001"
    assert_includes record_ids, "FR-PLATFORM000000001"
  end

  test "physically identical stop-work records deduplicate to one entry" do
    ledger = Rag::FieldRecordParser.parse_chunks([
      { content: GROUND_STOP_BLOCK, rank: 1, chunk_sha256: "sha_chunk_a" },
      { content: GROUND_STOP_BLOCK, rank: 2, chunk_sha256: "sha_chunk_b" }
    ])

    assert ledger.valid?
    assert_equal 1, ledger.records.size,
      "physically identical stop-work records must deduplicate to a single entry"
    assert_equal 2, ledger.records.sole.provenances.size,
      "deduped record must carry both chunk provenances"
  end

  test "absent evidence does not appear in the ledger" do
    ledger = Rag::FieldRecordParser.parse_chunks([
      { content: GROUND_STOP_BLOCK, rank: 1, chunk_sha256: "sha_x" }
    ])

    assert ledger.valid?
    assert_equal 1, ledger.records.size
    assert_empty ledger.records.select { |r| r.stop_trigger == "emergencia desde control de plataforma" },
      "platform-control record must not appear when absent from the extracted chunk"
  end
end
