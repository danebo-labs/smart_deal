# frozen_string_literal: true

require "test_helper"

class ReconcileBedrockCostJobTest < ActiveJob::TestCase
  DAY = Date.new(2026, 6, 18)

  setup do
    @orig_new = BedrockInvocationLogReconciler.method(:new)
    report = {
      date: DAY,
      rows: [
        { model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0", count: 52,
          input_tokens: 224_097, output_tokens: 22_213,
          cache_read_tokens: 0, cache_write_tokens: 0, cost: 0.33516 },
        { model_id: "amazon.titan-embed-text-v2:0", count: 106,
          input_tokens: 1_137, output_tokens: 0,
          cache_read_tokens: 0, cache_write_tokens: 0, cost: 0.00002 }
      ],
      total_cost: 0.33518
    }
    fake = Object.new
    fake.define_singleton_method(:day) { |_date| report }
    BedrockInvocationLogReconciler.define_singleton_method(:new) { |*_a, **_k| fake }
  end

  teardown do
    BedrockInvocationLogReconciler.define_singleton_method(:new, @orig_new)
    BedrockDailyCost.delete_all
  end

  test "persists one row per model for the given UTC day" do
    ReconcileBedrockCostJob.perform_now("2026-06-18")
    assert_equal 2, BedrockDailyCost.for_utc_day(DAY).count
    haiku = BedrockDailyCost.find_by(utc_date: DAY,
              model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0")
    assert_equal 224_097, haiku.input_tokens
    assert_equal 52,      haiku.invocation_count
    assert_in_delta 0.33516, haiku.cost_usd, 1e-6
    assert_in_delta 0.33518, BedrockDailyCost.total_cost(DAY), 1e-6
  end

  test "is idempotent — re-running replaces the day with no duplicates" do
    2.times { ReconcileBedrockCostJob.perform_now("2026-06-18") }
    assert_equal 2, BedrockDailyCost.for_utc_day(DAY).count
  end

  test "defaults to yesterday UTC when no date is given" do
    ReconcileBedrockCostJob.perform_now
    assert BedrockDailyCost.exists?(utc_date: Time.now.utc.to_date - 1)
  end
end
