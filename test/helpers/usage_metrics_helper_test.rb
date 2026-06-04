# frozen_string_literal: true

require "test_helper"

class UsageMetricsHelperTest < ActionView::TestCase
  include UsageMetricsHelper

  test "daily_usage_channel_rows mirrors home footer channel labels" do
    metrics = CostMetric.daily_snapshot(Date.current).merge(
      today_tokens_query: 100,
      today_cost_query: 0.01,
      today_tokens_anthropic_sonnet_direct: 200,
      today_cost_anthropic_sonnet_direct: 0.02
    )

    labels = daily_usage_channel_rows(metrics).pluck(:label)

    assert_includes labels, "Consultas (Bedrock Haiku)"
    assert_includes labels, "Parse sync (Sonnet)"
    assert_includes labels, "Parse batch (Sonnet)"
    assert_includes labels, "Embeddings (Titan)"
    assert_not_includes labels, "Bulk ZIP Opus (batch v1)"
    assert_equal UsageMetricsHelper::DAILY_USAGE_CHANNELS.size, labels.size
  end

  test "daily_usage_total_row matches snapshot totals" do
    metrics = { today_tokens: 999, today_cost: 0.42 }
    total = daily_usage_total_row(metrics)

    assert_equal "Total hoy", total[:label]
    assert_equal 999, total[:tokens]
    assert_in_delta 0.42, total[:cost]
  end
end
