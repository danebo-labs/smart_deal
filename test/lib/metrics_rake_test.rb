# frozen_string_literal: true

require "test_helper"

# Tests for lib/tasks/metrics.rake — specifically the rebuild_cost_rollups task.
# Uses SimpleMetricsService.update_database_metrics_only directly (the same method
# the task delegates to) to avoid loading Rake in unit tests.
class MetricsRakeTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    BedrockQuery.destroy_all
    CostMetric.destroy_all
  end

  test 'rebuild over two-day range produces correct per-day totals' do
    day1 = Date.new(2024, 3, 1)
    day2 = Date.new(2024, 3, 2)

    # Day 1: global haiku RAG query
    BedrockQuery.create!(
      model_id: 'global.anthropic.claude-haiku-4-5-20251001-v1:0',
      input_tokens: 1000, output_tokens: 200,
      source: 'query', user_query: 'what is this?',
      latency_ms: 100, created_at: day1.beginning_of_day
    )

    # Day 2: opus 4.8 direct parse
    BedrockQuery.create!(
      model_id: 'claude-opus-4-8-direct',
      input_tokens: 3000, output_tokens: 600,
      source: 'ingestion_parse', user_query: 'web_parse: doc.pdf',
      latency_ms: 200, created_at: day2.beginning_of_day
    )

    # Simulate what the task does
    [ day1, day2 ].each { |d| SimpleMetricsService.update_database_metrics_only(date: d) }

    day1_query_tok = CostMetric.find_by!(date: day1, metric_type: :daily_tokens_query).value.to_i
    day2_query_tok = CostMetric.find_by!(date: day2, metric_type: :daily_tokens_query).value.to_i
    day2_opus_tok  = CostMetric.find_by!(date: day2, metric_type: :daily_tokens_anthropic_opus_direct).value.to_i

    assert_equal 1200, day1_query_tok
    assert_equal 0,    day2_query_tok
    assert_equal 3600, day2_opus_tok
  end

  test 'rebuild is idempotent: running twice yields same CostMetric count and values' do
    day = Date.new(2024, 3, 5)

    BedrockQuery.create!(
      model_id: 'global.anthropic.claude-haiku-4-5-20251001-v1:0',
      input_tokens: 500, output_tokens: 100,
      source: 'query', user_query: 'q', latency_ms: 50,
      created_at: day.beginning_of_day
    )

    SimpleMetricsService.update_database_metrics_only(date: day)
    count1 = CostMetric.where(date: day).count
    val1   = CostMetric.find_by!(date: day, metric_type: :daily_tokens_query).value

    SimpleMetricsService.update_database_metrics_only(date: day)
    count2 = CostMetric.where(date: day).count
    val2   = CostMetric.find_by!(date: day, metric_type: :daily_tokens_query).value

    assert_equal count1, count2
    assert_equal val1,   val2
  end

  test 'per-day rebuild does not bleed into adjacent days' do
    day1 = Date.new(2024, 4, 1)
    day2 = Date.new(2024, 4, 2)

    BedrockQuery.create!(
      model_id: 'global.anthropic.claude-haiku-4-5-20251001-v1:0',
      input_tokens: 999, output_tokens: 111,
      source: 'query', user_query: 'x', latency_ms: 10,
      created_at: day1.end_of_day
    )

    SimpleMetricsService.update_database_metrics_only(date: day1)
    SimpleMetricsService.update_database_metrics_only(date: day2)

    day1_tok = CostMetric.find_by!(date: day1, metric_type: :daily_tokens_query).value.to_i
    day2_tok = CostMetric.find_by!(date: day2, metric_type: :daily_tokens_query).value.to_i

    assert_equal 1110, day1_tok
    assert_equal 0,    day2_tok
  end

  test 'corrected opus 4.7 batch price is used after rebuild' do
    day = Date.new(2024, 5, 1)

    BedrockQuery.create!(
      model_id: 'claude-opus-4-7',
      input_tokens: 1000, output_tokens: 1000,
      source: 'ingestion_parse', user_query: 'batch_parse: old.pdf',
      latency_ms: 50, created_at: day.beginning_of_day
    )

    SimpleMetricsService.update_database_metrics_only(date: day)

    cost = CostMetric.find_by!(date: day, metric_type: :daily_cost_parse).value.to_f
    # corrected: 1*0.0025 + 1*0.0125 = 0.015
    assert_in_delta 0.015, cost, 0.000001
  end
end
