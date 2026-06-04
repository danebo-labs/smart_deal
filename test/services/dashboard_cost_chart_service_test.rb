# frozen_string_literal: true

require "test_helper"

class DashboardCostChartServiceTest < ActiveSupport::TestCase
  setup do
    CostMetric.delete_all
    @month = Date.new(2026, 5, 1)
  end

  test "returns all calendar days for the month" do
    result = DashboardCostChartService.new(month: @month).call

    assert_equal 31, result[:labels].length
    assert_equal "1", result[:labels].first
    assert_equal "31", result[:labels].last
    assert_equal "mayo 2026", result[:title]
  end

  test "includes only channels with positive cost in the month" do
    CostMetric.create!(date: Date.new(2026, 5, 3), metric_type: :daily_cost_query, value: 0.05)
    CostMetric.create!(date: Date.new(2026, 5, 10), metric_type: :daily_cost_embed, value: 0.01)

    result = DashboardCostChartService.new(month: @month).call
    labels = result[:datasets].pluck(:label)

    assert_includes labels, "Consultas (Bedrock Haiku)"
    assert_includes labels, "Embeddings (Titan)"
    assert_not_includes labels, "Parse sync (Sonnet)"
  end

  test "fills missing days with zero for active channels" do
    CostMetric.create!(date: Date.new(2026, 5, 5), metric_type: :daily_cost_query, value: 0.12)

    result = DashboardCostChartService.new(month: @month).call
    query_series = result[:datasets].find { |d| d[:label] == "Consultas (Bedrock Haiku)" }

    assert_equal 31, query_series[:data].length
    assert_in_delta 0.0, query_series[:data][0]
    assert_in_delta 0.12, query_series[:data][4]
    assert_in_delta 0.0, query_series[:data][5]
  end

  test "returns empty datasets when month has no costs" do
    result = DashboardCostChartService.new(month: @month).call

    assert_empty result[:datasets]
  end
end
