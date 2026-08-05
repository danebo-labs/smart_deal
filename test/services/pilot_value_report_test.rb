# frozen_string_literal: true

require "test_helper"

class PilotValueReportTest < ActiveSupport::TestCase
  setup do
    @report = JSON.parse(
      Rails.root.join("test/fixtures/files/pilot_metrics_11_interactions.json").read
    )
  end

  test "derives the value layer from the documented real run of eleven interactions" do
    value = PilotValueReport.new(@report).as_json

    assert_equal 6, value.dig(:auditability, :answered_interactions)
    assert_equal 5, value.dig(:auditability, :audited_answers)
    assert_equal 0.8333, value.dig(:auditability, :audited_answer_rate)
    assert_equal 5, value.dig(:auditability, :pages_referenced)
    assert_equal 1.0, value.dig(:auditability, :citations_per_answer)

    assert_equal 5, value.dig(:precision_and_safety, :abstentions)
    assert_equal 0.4545, value.dig(:precision_and_safety, :abstention_rate)
    assert_equal 0.8333, value.dig(:precision_and_safety, :evidence_present_rate)
    assert_equal 0, value.dig(:precision_and_safety, :attribution_dropped)
    assert_equal "n/a", value.dig(:precision_and_safety, :verified_correct_rate)
    assert_equal "REQUIRES_HUMAN_REVIEW", value.dig(:precision_and_safety, :verification_status)

    assert_equal 0.006275, value.dig(:value_capture, :cost_per_answered_interaction_usd)
    assert_equal 5.815, value.dig(:value_capture, :answer_time_p50_s)
    assert_equal 6.742, value.dig(:value_capture, :answer_time_p95_s)
    assert_equal "n/a", value.dig(:value_capture, :prompt_cache_tokens_saved)

    assert_equal 1, value.dig(:adoption, :active_users)
    assert_equal 0, value.dig(:adoption, :returning_users)
    assert_equal 1, value.dig(:adoption, :repeated_questions)
    assert_equal 1, value.dig(:adoption, :sessions)
    assert_equal 1, value.dig(:adoption, :active_days)
  end

  test "uses manual review only when present and never invents a zero rate" do
    unavailable = PilotValueReport.new(@report).as_json
    assert_equal "n/a", unavailable.dig(:precision_and_safety, :verified_correct_rate)

    reviewed = Marshal.load(Marshal.dump(@report))
    reviewed.dig("interactions", "by_correlation")[1]["correct_answer"] = "yes"
    reviewed.dig("interactions", "by_correlation")[2]["correct_answer"] = "no"
    value = PilotValueReport.new(reviewed).as_json

    assert_equal 0.5, value.dig(:precision_and_safety, :verified_correct_rate)
    assert_equal "available", value.dig(:precision_and_safety, :verification_status)
    assert_equal 2, value.dig(:precision_and_safety, :reviewed_interactions)
  end
end
