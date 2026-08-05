# frozen_string_literal: true

require "test_helper"
require "stringio"

class BedrockRagServiceAuditTest < ActiveSupport::TestCase
  setup do
    @service = BedrockRagService.allocate
    @service.instance_variable_set(:@model_ref, "test-model")
    @service.instance_variable_set(:@knowledge_base_id, "test-kb")
  end

  test "disabled gate leaves the emitted quality line unchanged and emits no audit lines" do
    travel_to Time.zone.local(2026, 8, 5, 12) do
      without_audit = with_audit_capture(nil) { capture_quality_signal }
      explicitly_disabled = with_audit_capture("false") { capture_quality_signal }

      assert_equal without_audit, explicitly_disabled
      assert_equal 1, without_audit.lines.size
      assert_includes without_audit, "[RAG_QUALITY]"
      assert_not_includes without_audit, "[PILOT_AUDIT]"
    end
  end

  test "enabled gate emits complete interaction and bounded chunk lines without PilotUsageLog raw text" do
    question = "Q" * 1_000
    answer = "A" * 2_000
    chunk_text = "chunk " * 900
    pilot_usage_calls = []
    original_log = PilotUsageLog.method(:log)
    PilotUsageLog.define_singleton_method(:log) do |event, **fields|
      pilot_usage_calls << [ event, fields ]
    end

    output = with_audit_capture("true") do
      capture_quality_signal(question: question, answer: answer, chunk_text: chunk_text)
    end
    lines = output.lines.grep(/\[PILOT_AUDIT\]/)

    assert_equal 2, lines.size
    assert lines.all? { |line| line.bytesize < 8.kilobytes }

    interaction = parse_audit(lines.first)
    assert_equal "interaction", interaction["type"]
    assert_equal question, interaction["question"]
    assert_equal answer, interaction["answer"]
    assert_equal answer.length, interaction["answer_length"]
    assert_equal [
      { "number" => 1, "title" => "Manual — p. 14", "filename" => "manual.pdf", "page" => 14 }
    ], interaction["citations"]

    chunk = parse_audit(lines.second)
    assert_equal "chunk", chunk["type"]
    assert_equal "Manual", chunk["document"]
    assert_equal 14, chunk["page"]
    assert_equal "SEC-14", chunk["section_identity"]
    assert_equal Digest::SHA256.hexdigest(chunk_text), chunk["chunk_sha256"]
    assert_equal 4_000, chunk["text"].length
    assert_equal true, chunk["truncated"]
    assert_empty pilot_usage_calls
  ensure
    PilotUsageLog.define_singleton_method(:log) do |event, **fields|
      original_log.call(event, **fields)
    end if original_log
  end

  test "chunk byte ceiling accounts for JSON escaping" do
    chunk_text = "\u0000" * 4_000
    output = with_audit_capture("true") do
      capture_quality_signal(chunk_text: chunk_text)
    end
    line = output.lines.grep(/\[PILOT_AUDIT\]/).second
    chunk = parse_audit(line)

    assert_operator line.bytesize, :<=, 8.kilobytes
    assert_operator chunk["text"].length, :<, 4_000
    assert_equal true, chunk["truncated"]
  end

  private

  def capture_quality_signal(question: "Q" * 500, answer: "A" * 800, chunk_text: "short chunk")
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    @service.send(
      :log_quality_signal,
      question: question,
      answer: answer,
      citations: [ { number: 1, title: "Manual — p. 14", filename: "manual.pdf", page: 14 } ],
      doc_refs: [],
      raw_citations: [ Object.new ],
      latency_ms: 120,
      entity_filter: [],
      evidence_mode: "bedrock_citations",
      retrieved_chunks: [
        {
          content: chunk_text,
          metadata: {
            "canonical_name" => "Manual",
            "page_number" => 14,
            "section_identity" => "SEC-14"
          }
        }
      ],
      canned_no_results: false,
      canned_with_retrieval: false,
      correlation_id: "query:audit",
      attribution: { account_id: 1, user_id: 2, conversation_session_id: 3 },
      citation_attribution: OpenStruct.new(dropped_segments: [], anchors: [], identities: [])
    )
    output.string
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  def parse_audit(line)
    JSON.parse(line.split("[PILOT_AUDIT] ", 2).last)
  end

  def with_audit_capture(value)
    previous = ENV["PILOT_AUDIT_CAPTURE"]
    value.nil? ? ENV.delete("PILOT_AUDIT_CAPTURE") : ENV["PILOT_AUDIT_CAPTURE"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("PILOT_AUDIT_CAPTURE") : ENV["PILOT_AUDIT_CAPTURE"] = previous
  end
end
