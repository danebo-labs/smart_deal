# frozen_string_literal: true

require "test_helper"
require_relative "../../script/field_companion/ingestion_model_refresh"

class FieldCompanionIngestionModelRefreshTest < ActiveSupport::TestCase
  Refresh = FieldCompanion::IngestionModelRefresh

  test "worst case bills the output cap and cache-write input, not default rates" do
    cost = Refresh.worst_case_usd(1_000)

    assert_equal BigDecimal("0.04125"), cost
    assert_not_equal BigDecimal("0.00025"), Refresh::RATES.fetch("input")
    rates = BedrockQuery::BEDROCK_PRICING.fetch("claude-sonnet-5-5-batch")
    assert_equal({ input: 0.001, output: 0.005, cache_read: 0.0001, cache_creation: 0.00125 }, rates)
    assert_not_equal BedrockQuery::BEDROCK_PRICING.fetch("default"), rates
  end

  test "batch cost separates input, output, cache read and cache creation" do
    priced = Refresh.batch_cost(
      "input_tokens" => 1_000,
      "output_tokens" => 1_000,
      "cache_read_input_tokens" => 1_000,
      "cache_creation_input_tokens" => 1_000,
      "cache_creation_1h_input_tokens" => 0
    )

    assert_equal "0.001", priced["input"]
    assert_equal "0.005", priced["output"]
    assert_equal "0.0001", priced["cache_read"]
    assert_equal "0.00125", priced["cache_creation"]
    assert_equal "0.00735", priced["total"]
  end

  test "decision gate prefers sonnet 5.5 when scored fields do not regress" do
    decision = Refresh.decide(per_unit: [ unit_row("PASS", "PASS") ], compatibility_fail: false)

    assert_equal "I1", decision["gate"]
  end

  test "decision gate rejects a new safety failure or a pass that becomes a fail" do
    safety = Refresh.decide(per_unit: [ unit_row("PASS", "FAIL", safety_55: true) ], compatibility_fail: false)
    regression = Refresh.decide(per_unit: [ unit_row("PASS", "FAIL") ], compatibility_fail: false)
    incompatible = Refresh.decide(per_unit: [ unit_row("PASS", "PASS") ], compatibility_fail: true)

    assert_equal "I2", safety["gate"]
    assert_equal "new_safety_fail", safety["regressions"].first["kind"]
    assert_equal "I2", regression["gate"]
    assert_equal "regression", regression["regressions"].first["kind"]
    assert_equal "I2", incompatible["gate"]
  end

  test "decision gate is inconclusive when nothing is scored" do
    decision = Refresh.decide(per_unit: [ { "id" => "empty", "status" => "excluded", "fields" => [] } ], compatibility_fail: false)

    assert_equal "I3", decision["gate"]
  end

  test "decision gate rejects a structural failure on sonnet 5.5" do
    unit = unit_row("FAIL", "FAIL")
    unit["fields"].each { |field| field["category"] = "structural" }
    decision = Refresh.decide(per_unit: [ unit ], compatibility_fail: false)

    assert_equal "I2", decision["gate"]
    assert_equal "structural_fail", decision["reason"]
  end

  test "control submission sends only sonnet 5 and does not repeat a live batch" do
    requests = Array.new(5) { { params: { model: "claude-sonnet-5" } } }
    void = { "batch_id" => Refresh::VOID_BATCH_ID, "model" => "claude-sonnet-5", "api_status" => "canceled", "status" => "void" }
    fresh = Refresh.control_submission_plan(waves: [ void ], requests: requests)
    live = Refresh.control_submission_plan(
      waves: [ void, { "batch_id" => "msgbatch_new", "model" => "claude-sonnet-5", "control_only" => true, "status" => "submitted" } ],
      requests: requests
    )

    assert fresh["submit"]
    assert_equal [ "claude-sonnet-5" ], fresh["models"]
    assert_not live["submit"]
    assert_equal "msgbatch_new", live["existing_batch_id"]
    assert_raises(Refresh::Stop) do
      Refresh.control_submission_plan(waves: [ void ], requests: [ { params: { model: "claude-sonnet-5-5" } } ])
    end
  end

  test "semantic payload hash ignores the model id" do
    left = { custom_id: "page", params: { model: "claude-sonnet-5", max_tokens: 8_000, system: [ { text: "same" } ], messages: [] } }
    right = { custom_id: "page", params: { model: "claude-sonnet-5-5", max_tokens: 8_000, system: [ { text: "same" } ], messages: [] } }

    assert_equal Refresh.semantic_sha(left), Refresh.semantic_sha(right)
    assert_not_equal Refresh.semantic_sha(left), Refresh.semantic_sha(left.merge(custom_id: "other"))
  end

  private

  def unit_row(left, right, safety_55: false)
    {
      "id" => "page",
      "status" => "scored",
      "fields" => [
        { "id" => "visible", "model" => "claude-sonnet-5", "category" => "visible_text", "result" => left, "safety" => false },
        { "id" => "visible", "model" => "claude-sonnet-5-5", "category" => "visible_text", "result" => right, "safety" => safety_55 }
      ]
    }
  end
end
