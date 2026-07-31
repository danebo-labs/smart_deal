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

  test "logs structured route budget, expansion, timings, and abstention" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    assert Rag::EvidenceSelectionTelemetry.log_route(
      question: "¿Qué indica el LED ABC12?",
      answer: "El documento no incluye este dato — requiere verificación en campo.",
      generation_mode: "structured_evidence_route",
      account_id: 1,
      user_id: 2,
      conversation_session_id: 3,
      correlation_id: "corr-2",
      retrieval_budget: 12,
      expansion_mechanisms: [ :section_identity ],
      outcome: :abstained,
      outcome_reason: :generation_failure,
      verbatim_directive: true,
      generation_input_tokens: 240,
      generation_output_tokens: 12,
      generation_prompt_chars: 960,
      timings: {
        retrieval_ms: 20,
        expansion_ms: 5,
        local_ms: 2,
        generation_ms: 30,
        generation_chunks: 5
      }
    )

    line = output.string.lines.find { |entry| entry.include?('"event":"evidence_route"') }
    payload = JSON.parse(line.split("[PILOT_USAGE] ", 2).last)
    assert_equal 12, payload["retrieval_budget"]
    assert_equal true, payload["expansion_used"]
    assert_equal "section_identity", payload["expansion_mechanism"]
    assert_equal "structured_evidence_route", payload["route_taken"]
    assert_equal true, payload["abstention"]
    assert_equal "abstained", payload["outcome"]
    assert_equal "generation_failure", payload["outcome_reason"]
    assert_equal true, payload["verbatim_directive"]
    assert_equal 20, payload["retrieval_ms"]
    assert_equal 5, payload["expansion_ms"]
    assert_equal 2, payload["local_ms"]
    assert_equal 30, payload["generation_ms"]
    assert_equal 5, payload["generation_chunks"]
    assert_equal 240, payload["generation_input_tokens"]
    assert_equal 12, payload["generation_output_tokens"]
    assert_equal 960, payload["generation_prompt_chars"]
    assert_not payload.key?("ambiguity_detected")
    assert_not payload.key?("ambiguity_identifier")
    assert_not payload.key?("ambiguity_families")
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "logs the cross-family ambiguity verdict, identifier and boards" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    assert Rag::EvidenceSelectionTelemetry.log_route(
      question: "¿A qué serie corresponde el LED SPM?",
      answer: "El significado depende de la placa. [1][2]",
      generation_mode: "structured_evidence_route",
      account_id: 1,
      user_id: 2,
      conversation_session_id: 3,
      correlation_id: "corr-3",
      retrieval_budget: 12,
      expansion_mechanisms: [],
      outcome: :answered,
      outcome_reason: nil,
      verbatim_directive: true,
      generation_input_tokens: 300,
      generation_output_tokens: 60,
      generation_prompt_chars: 1_200,
      ambiguity_detected: true,
      ambiguity_identifier: "SPM",
      ambiguity_families: [ "CARLOS SILVA TPR50", "TWISTER TW - INAPELSA", "DELTA +" ],
      timings: {
        retrieval_ms: 20,
        expansion_ms: 0,
        local_ms: 3,
        generation_ms: 40,
        generation_chunks: 3
      }
    )

    line = output.string.lines.find { |entry| entry.include?('"event":"evidence_route"') }
    payload = JSON.parse(line.split("[PILOT_USAGE] ", 2).last)

    assert_equal true, payload["ambiguity_detected"]
    assert_equal "SPM", payload["ambiguity_identifier"]
    assert_equal [ "CARLOS SILVA TPR50", "TWISTER TW - INAPELSA", "DELTA +" ],
                 payload["ambiguity_families"]
    assert_equal false, payload["abstention"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "logs the model id and attribution identities/anchors on evidence_route" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    attribution = Struct.new(:identities, :anchors).new([ "CARLOS SILVA", "SISTEL" ], [ "CARLOS SILVA" ])

    assert Rag::EvidenceSelectionTelemetry.log_route(
      question: "¿A qué serie corresponde el LED SPM?",
      answer: "El significado depende de la placa. [1][2]",
      generation_mode: "structured_evidence_route",
      account_id: 1,
      user_id: 2,
      conversation_session_id: 3,
      correlation_id: "corr-4",
      retrieval_budget: 12,
      expansion_mechanisms: [],
      outcome: :answered,
      outcome_reason: nil,
      verbatim_directive: true,
      generation_input_tokens: 300,
      generation_output_tokens: 60,
      generation_prompt_chars: 1_200,
      model: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      attribution: attribution,
      timings: {
        retrieval_ms: 20,
        expansion_ms: 0,
        local_ms: 3,
        generation_ms: 40,
        generation_chunks: 0
      }
    )

    line = output.string.lines.find { |entry| entry.include?('"event":"evidence_route"') }
    payload = JSON.parse(line.split("[PILOT_USAGE] ", 2).last)

    assert_equal "global.anthropic.claude-haiku-4-5-20251001-v1:0", payload["model"]
    assert_equal [ "CARLOS SILVA", "SISTEL" ], payload["attribution_identities"]
    assert_equal [ "CARLOS SILVA" ], payload["attribution_anchors"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "emits one evidence_route_context event per generation chunk with page, section and source" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    chunks = [
      {
        content: "SPM | SERIE PUERTAS CABINA - EXTERIORES",
        metadata: {
          "document_id" => "doc-tpr50",
          "original_source_uri" => "s3://bucket/seguridades.pdf",
          "page_number" => 9,
          "section_identity" => "CARLOS SILVA"
        },
        chunk_sha256: "spm-tpr50"
      },
      {
        content: "SPM | SERIE DE PUERTAS",
        metadata: {
          "document_id" => "doc-twister",
          "original_source_uri" => "s3://bucket/seguridades.pdf",
          "page_number" => 88,
          "section_identity" => "SISTEL"
        },
        chunk_sha256: "spm-twister"
      }
    ]
    expansions = [
      { divider_chunk_sha256: "divider-1", neighbor_chunk_sha256: "spm-twister", mechanism: :section_identity }
    ]

    assert Rag::EvidenceSelectionTelemetry.log_route(
      question: "¿A qué serie corresponde el LED SPM?",
      answer: "El significado depende de la placa. [1][2]",
      generation_mode: "structured_evidence_route",
      account_id: 1,
      user_id: 2,
      conversation_session_id: 3,
      correlation_id: "corr-5",
      retrieval_budget: 12,
      expansion_mechanisms: [ :section_identity ],
      outcome: :answered,
      outcome_reason: nil,
      verbatim_directive: true,
      generation_input_tokens: 300,
      generation_output_tokens: 60,
      generation_prompt_chars: 1_200,
      chunks: chunks,
      expansions: expansions,
      timings: {
        retrieval_ms: 20,
        expansion_ms: 5,
        local_ms: 3,
        generation_ms: 40,
        generation_chunks: 2
      }
    )

    contexts = output.string.lines
      .grep(/"event":"evidence_route_context"/)
      .map { |line| JSON.parse(line.split("[PILOT_USAGE] ", 2).last) }

    assert_equal 2, contexts.size
    tpr50 = contexts.find { |payload| payload["chunk_sha256"] == "spm-tpr50" }
    twister = contexts.find { |payload| payload["chunk_sha256"] == "spm-twister" }

    assert_equal "doc-tpr50", tpr50["document_id"]
    assert_equal "s3://bucket/seguridades.pdf", tpr50["source_uri"]
    assert_equal 9, tpr50["page"]
    assert_equal "CARLOS SILVA", tpr50["section_identity"]
    assert_equal "none", tpr50["expansion_mechanism"]
    assert_equal 64, tpr50["excerpt_sha256"].length
    assert_equal Digest::SHA256.hexdigest(chunks.first[:content].first(200)), tpr50["excerpt_sha256"]

    assert_equal "section_identity", twister["expansion_mechanism"]
    assert_equal 3, twister["conversation_session_id"]
    assert_equal "corr-5", twister["correlation_id"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "abstained route with no generation chunks emits no evidence_route_context events" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    assert Rag::EvidenceSelectionTelemetry.log_route(
      question: "¿Qué indica el LED ABC12?",
      answer: "El documento no incluye este dato.",
      generation_mode: "structured_evidence_route",
      account_id: 1,
      user_id: 2,
      conversation_session_id: 3,
      correlation_id: "corr-6",
      retrieval_budget: 12,
      expansion_mechanisms: [],
      outcome: :abstained,
      outcome_reason: :empty_evidence,
      verbatim_directive: false,
      generation_input_tokens: nil,
      generation_output_tokens: nil,
      generation_prompt_chars: nil,
      chunks: [],
      timings: {
        retrieval_ms: 20,
        expansion_ms: 0,
        local_ms: 0,
        generation_ms: 0,
        generation_chunks: 0
      }
    )

    assert_empty output.string.lines.grep(/"event":"evidence_route_context"/)
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end
