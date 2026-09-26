# frozen_string_literal: true

require "test_helper"

class Rag::RealGonzaloSemanticAccountingTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("test/fixtures/real_gonzalo/semantic_accounting_2026-09-25.json")

  test "the audited semantic aggregate is 16 calls, 22896 in, 1719 out, and USD 0.031491" do
    fixture = JSON.parse(FIXTURE_PATH.read)
    ids = fixture.fetch("correlation_ids")

    assert_equal 16, fixture.fetch("calls")
    assert_equal 16, ids.size
    assert_equal 16, ids.uniq.size
    assert_includes ids, "photo:e9cea10e-559d-490c-bd2a-8eea8f9418c1"
    assert_equal 15, ids.count { |id| id.start_with?("query:") }
    assert_not_includes ids, fixture.fetch("blank_photo_correlation_id")
    assert_equal 22_896, fixture.fetch("input_tokens")
    assert_equal 1_719, fixture.fetch("output_tokens")
    assert_equal 0.031491, fixture.fetch("cost_usd")
    assert fixture.keys.none? { |key| key.match?(/per_call|token_split|calls_detail/) }
    ids.each do |id|
      assert_equal id, id.to_s
    end

    cost = BedrockQuery.new(
      model_id: fixture.fetch("model_id"),
      input_tokens: fixture.fetch("input_tokens"),
      output_tokens: fixture.fetch("output_tokens")
    ).cost
    assert_equal 0.031491, cost
    assert_equal fixture.fetch("cost_usd"), cost
  end

  test "one correlation joins semantic usage, retrieval evidence, and the delivered answer without a second cost" do
    correlation_id = "query:4243acf2-0f45-474e-a293-07e5432242bb"
    delivered = "La placa MPK 708A almacena hasta 50 eventos."
    BedrockQuery.create!(
      source: "semantic_analysis", route: "semantic_analysis",
      model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      input_tokens: 400, output_tokens: 30, latency_ms: 20, user_query: "MPK 708A",
      correlation_id: correlation_id, token_source: "provider_usage"
    )
    BedrockQuery.create!(
      source: "query", route: "rag_global",
      model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      input_tokens: 800, output_tokens: 40, latency_ms: 90, user_query: "MPK 708A",
      correlation_id: correlation_id, token_source: "estimated"
    )

    evidence = Rag::TurnEvidence.build(
      correlation_id: correlation_id,
      route: "text",
      outcome: "answered",
      original_query: "MPK 708A",
      effective_query: "MPK 708A",
      answer: delivered,
      semantic: { "status" => "ok", "relation" => "new", "ambiguous" => false },
      chunk_ids: [ "mpk-p1" ],
      sources: [ { "title" => "Listado Fallas MPK 708A", "page" => 1 } ]
    )
    rows = BedrockQuery.where(correlation_id: evidence["correlation_id"])

    assert_equal 2, rows.count
    assert_equal %w[query semantic_analysis], rows.map(&:source).sort
    assert_equal 1, rows.count { |row| row.source == "semantic_analysis" }
    assert_equal 1, rows.count { |row| row.source == "query" }
    assert_equal Digest::SHA256.hexdigest(delivered), evidence["answer_sha256"]
    assert_equal [ "mpk-p1" ], evidence["chunk_ids"]
    assert_not evidence.key?("cost")
    assert_not evidence.key?("cost_usd")
  end
end
