# frozen_string_literal: true

require "test_helper"

class Rag::EvidenceSelectionTelemetryTest < ActiveSupport::TestCase
  test "persists the complete summary and per-context evidence contract" do
    context = Rag::EvidenceSelection::EvidenceContext.new(
      section_key: "CARLOS SILVA",
      board_key: "TPR50",
      label: "HIDRA — TPR50",
      breadcrumb: [ "HIDRA — TPR50", "CARLOS SILVA", "SEGURIDADES 1.1-1" ],
      document_id: "doc-1",
      source_uri: "s3://bucket/manual.pdf",
      page_number: 9,
      evidence_target: "https://example.test/manual.pdf#page=9",
      evidence_excerpt: "SPM | SERIE PUERTAS CABINA – EXTERIORES",
      identifiers: [],
      relations_covered: Set[:attribution],
      chunk_sha256: "chunk-sha",
      rank: 1,
      match_reason: :direct
    )
    selection = Rag::EvidenceSelection.new(
      mode: :direct,
      contexts: [ context ],
      answered_relations: Set[:attribution],
      abstained_relations: Set[:state],
      rejections: [
        Rag::EvidenceSelection::Rejection.new(chunk_sha256: "rejected", stage: 3, reason: :relation_not_documented)
      ],
      expansions: [],
      selector_version: "selector-v1"
    )

    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    assert Rag::EvidenceSelectionTelemetry.log(
      selection: selection,
      question: "¿A qué serie corresponde SPM?",
      answer: "SPM corresponde a puertas exteriores.",
      generation_mode: "generative",
      account_id: 1,
      user_id: 2,
      conversation_session_id: 3,
      correlation_id: "corr-1",
      sources_visible: false
    )

    payloads = output.string.lines
      .grep(/\[PILOT_USAGE\]/)
      .map { |line| JSON.parse(line.split("[PILOT_USAGE] ", 2).last) }
    summary = payloads.find { |payload| payload["event"] == "evidence_selection" }
    evidence = payloads.find { |payload| payload["event"] == "evidence_selection_context" }

    assert_equal "direct", summary["resolution_mode"]
    assert_equal false, summary["needs_selection"]
    assert_equal [ "attribution" ], summary["answered_relations"]
    assert_equal [ "state" ], summary["abstained_relations"]
    assert_equal 1, summary["contexts_delivered"]
    assert_equal 1, summary["groups_total"]
    assert_equal "selector-v1", summary["selector_version"]
    assert_equal "none", summary["expansion_mechanism"]
    assert_equal [ "relation_not_documented:1" ], summary["rejection_reasons"]
    assert_equal false, summary["sources_visible"]
    assert_equal 64, summary["question_sha256"].length
    assert_equal 64, summary["answer_sha256"].length

    assert_equal "doc-1", evidence["document_id"]
    assert_equal 9, evidence["page"]
    assert_equal "chunk-sha", evidence["chunk_sha256"]
    assert_equal context.evidence_excerpt, evidence["excerpt"]
    assert_equal 64, evidence["excerpt_sha256"].length
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end
