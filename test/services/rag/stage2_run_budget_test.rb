# frozen_string_literal: true

require "test_helper"

class Rag::Stage2RunBudgetTest < ActiveSupport::TestCase
  test "the closed pass keeps the observed spend and does not admit another" do
    spent = Rag::Stage2RunBudget.snapshot(new_calls: 0, new_cost_usd: 0)

    assert_equal 132, spent.calls
    assert_equal 132, spent.historical_calls
    assert_equal 0, spent.new_calls
    assert_equal BigDecimal("0.275813"), spent.cost_usd
    assert_equal BigDecimal("0.275813"), spent.historical_cost_usd
    assert_not spent.admit_turn
    assert_equal 0, spent.pass_calls_remaining
    assert_equal 16, spent.stage2_calls_remaining
    assert_equal 16, spent.global_calls_remaining
    assert_operator spent.stage2_calls_remaining, :>=, Rag::Stage2RunBudget::TURN_CALL_MARGIN
    assert_not Rag::Stage2RunBudget.admit_turn?(new_calls: 0, new_cost_usd: 0)
    assert_not Rag::Stage2RunBudget.admit_turn?(new_calls: 0, new_cost_usd: BigDecimal("2.30"))
  end

  test "the stage 3 reserve stays inside the global ceiling" do
    assert_equal 148, Rag::Stage2RunBudget::GLOBAL_CALL_CEILING - Rag::Stage2RunBudget::STAGE3_CALL_RESERVE
    assert_equal 16, Rag::Stage2RunBudget::STAGE2_CALL_CEILING - Rag::Stage2RunBudget::HISTORICAL_CALLS
    assert_equal 42, Rag::Stage2RunBudget::STAGE3_CALL_RESERVE
    assert_equal BigDecimal("2.50"), Rag::Stage2RunBudget::COST_CAP_USD
    assert_operator(
      Rag::Stage2RunBudget::HISTORICAL_CALLS + Rag::Stage2RunBudget::STAGE3_CALL_RESERVE,
      :<=,
      Rag::Stage2RunBudget::GLOBAL_CALL_CEILING
    )
    assert_equal 3, Rag::Stage2RunBudget::TURN_CALL_MARGIN
  end

  test "each run gets its own directory and the manifest keeps the sha and the historical spend" do
    root = Pathname.new("/tmp/stage2_journey_a")
    first = Rag::Stage2RunBudget.evidence_directory(root, run_id: "20261007T191300Z", session_id: 196)
    second = Rag::Stage2RunBudget.evidence_directory(root, run_id: "20261007T191301Z", session_id: 197)
    manifest = Rag::Stage2RunBudget.manifest(
      sha: "abc123", session_id: 196, run_id: "20261007T191300Z"
    )

    assert_equal root.join("runs/20261007T191300Z-session-196"), first
    assert_not_equal first, second
    assert_not_equal root, first
    assert_equal "abc123", manifest["sha"]
    assert_equal 132, manifest["historical_calls"]
    assert_equal "0.275813", manifest["historical_cost_usd"]
    assert_equal 0, manifest["pass_call_cap"]
    assert_equal 42, manifest["stage3_call_reserve"]
    assert_equal 190, manifest["global_call_ceiling"]
    assert_equal 3, manifest["turn_call_margin"]
    assert_raises(ArgumentError) { Rag::Stage2RunBudget.evidence_directory(root, run_id: "../trace", session_id: 1) }
  end
end
