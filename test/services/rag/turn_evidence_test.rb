# frozen_string_literal: true

require "test_helper"

class Rag::TurnEvidenceTest < ActiveSupport::TestCase
  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/real_gonzalo/semantic_accounting_2026-09-25.json").read)
  BLANK_PHOTO = FIXTURE.fetch("blank_photo_correlation_id")
  TEXT_TURN = "query:4243acf2-0f45-474e-a293-07e5432242bb"
  EMPTY_SHA = Digest::SHA256.hexdigest("")

  setup do
    @previous_capture = ENV["PILOT_AUDIT_CAPTURE"]
    ENV.delete("PILOT_AUDIT_CAPTURE")
  end

  teardown do
    if @previous_capture.nil?
      ENV.delete("PILOT_AUDIT_CAPTURE")
    else
      ENV["PILOT_AUDIT_CAPTURE"] = @previous_capture
    end
  end

  test "a blank photo record keeps the empty query hash, target visibility, and no cost or raw text" do
    payload = Rag::TurnEvidence.build(
      correlation_id: BLANK_PHOTO,
      route: "visual_query",
      outcome: "answered",
      original_query: "",
      effective_query: "",
      answer: "Se ve un conjunto de cabina y puerta.",
      photo: { "intent_source" => "history", "target_visible" => false },
      chunk_ids: [],
      sources: []
    )

    assert_equal BLANK_PHOTO, payload["correlation_id"]
    assert_equal EMPTY_SHA, payload["original_query_sha256"]
    assert_equal EMPTY_SHA, payload["effective_query_sha256"]
    assert_equal false, payload.dig("photo", "target_visible")
    assert_equal "history", payload.dig("photo", "intent_source")
    assert_nil payload["semantic"]
    assert_equal Digest::SHA256.hexdigest("Se ve un conjunto de cabina y puerta."), payload["answer_sha256"]
    assert_not payload.key?("original_query")
    assert_not payload.key?("effective_query")
    assert_not payload.key?("answer")
    assert_empty payload.keys & %w[cost cost_usd input_tokens output_tokens cache_read_tokens cache_creation_tokens original_cost]
  end

  test "a text turn stores hashes and captures raw text only when the audit flag is on" do
    question = "¿Qué significa el código de error de la tarjeta MPK 708A?"
    delivered = "La placa almacena hasta 50 eventos."
    common = {
      correlation_id: TEXT_TURN,
      route: "text",
      outcome: "answered",
      original_query: question,
      effective_query: question,
      answer: delivered,
      semantic: { "status" => "ok", "relation" => "switch", "ambiguous" => false },
      chunk_ids: [ "chunk-4243" ],
      sources: [ { "title" => "MPK 708A", "page" => 1 } ]
    }

    hidden = Rag::TurnEvidence.build(**common)
    assert_equal Digest::SHA256.hexdigest(question), hidden["original_query_sha256"]
    assert_equal Digest::SHA256.hexdigest(delivered), hidden["answer_sha256"]
    assert_equal [ "chunk-4243" ], hidden["chunk_ids"]
    assert_equal({ "title" => "MPK 708A", "page" => 1 }, hidden["sources"].first)
    assert_equal "ok", hidden.dig("semantic", "status")
    assert_equal false, hidden.dig("semantic", "ambiguous")
    assert_not hidden.key?("answer")

    ENV["PILOT_AUDIT_CAPTURE"] = "true"
    captured = Rag::TurnEvidence.build(**common)
    assert_equal question, captured["original_query"]
    assert_equal question, captured["effective_query"]
    assert_equal delivered, captured["answer"]
    assert_empty captured.keys & %w[cost cost_usd input_tokens output_tokens]
  end

  test "citation evidence keeps chunk ids and title plus page" do
    ids, sources = Rag::TurnEvidence.evidence_from([
      {
        chunk_sha256: "chunk-1",
        content: "full body that must not be stored",
        metadata: { "canonical_name" => "Manual", "page_number" => 4 }
      }
    ])

    assert_equal [ "chunk-1" ], ids
    assert_equal [ { "title" => "Manual", "page" => 4 } ], sources
  end

  test "the log line is joinable by correlation_id and is not a second cost authority" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    Rag::SourceFidelityGuard.call(
      answer: "El fusible abre a 12 V.",
      evidence_texts: [ "Sin esa tension." ],
      allowed_texts: [],
      locale: :es,
      correlation_id: TEXT_TURN
    )
    payload = Rag::TurnEvidence.log(
      correlation_id: TEXT_TURN,
      route: "text",
      outcome: "answered",
      original_query: "pregunta",
      effective_query: "pregunta efectiva",
      answer: "respuesta entregada"
    )

    evidence_line = output.string.lines.find { |line| line.include?("[TURN_EVIDENCE]") }
    guard_line = output.string.lines.find { |line| line.include?("source_fidelity_guard") }
    evidence = JSON.parse(evidence_line.split("[TURN_EVIDENCE] ", 2).last)
    guard = JSON.parse(guard_line[guard_line.index("{")..])
    assert_equal TEXT_TURN, evidence["correlation_id"]
    assert_equal TEXT_TURN, guard["correlation_id"]
    assert_equal payload["answer_sha256"], evidence["answer_sha256"]
    assert_not evidence.key?("removed")
    assert_not evidence.key?("cost")
    assert_not_equal Digest::SHA256.hexdigest("pre-guard"), evidence["answer_sha256"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end
