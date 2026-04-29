# frozen_string_literal: true

# app/controllers/concerns/metrics_helper.rb
module MetricsHelper
  extend ActiveSupport::Concern

  private

  def current_metrics
    today = Date.current

    # Ensure today's DB metrics (tokens, cost, queries) are synced from BedrockQuery.
    # CostMetric is only populated after each query; without this, metrics would show 0
    # on first page load or after server restart before any query runs.
    sync_today_database_metrics_if_missing(today)

    s3_size_bytes = CostMetric.find_by(date: today, metric_type: :s3_total_size)&.value || 0

    {
      today_tokens:        CostMetric.find_by(date: today, metric_type: :daily_tokens)&.value        || 0,
      today_cost:          CostMetric.find_by(date: today, metric_type: :daily_cost)&.value          || 0,
      today_queries:       CostMetric.find_by(date: today, metric_type: :daily_queries)&.value       || 0,
      today_tokens_query:  CostMetric.find_by(date: today, metric_type: :daily_tokens_query)&.value  || 0,
      today_tokens_parse:  CostMetric.find_by(date: today, metric_type: :daily_tokens_parse)&.value  || 0,
      today_tokens_embed:  CostMetric.find_by(date: today, metric_type: :daily_tokens_embed)&.value  || 0,
      today_cost_query:    CostMetric.find_by(date: today, metric_type: :daily_cost_query)&.value    || 0,
      today_cost_parse:    CostMetric.find_by(date: today, metric_type: :daily_cost_parse)&.value    || 0,
      today_cost_embed:    CostMetric.find_by(date: today, metric_type: :daily_cost_embed)&.value    || 0,
      today_cache_hits:    CostMetric.find_by(date: today, metric_type: :daily_cache_hits)&.value    || 0,
      today_tokens_saved:  CostMetric.find_by(date: today, metric_type: :daily_tokens_saved)&.value  || 0,
      aurora_acu:          CostMetric.find_by(date: today, metric_type: :aurora_acu_avg)&.value      || 0,
      s3_documents:        CostMetric.find_by(date: today, metric_type: :s3_documents_count)&.value  || 0,
      s3_size_mb:          (s3_size_bytes / 1.megabyte.to_f).round(2),
      s3_size_gb:          (s3_size_bytes / 1.gigabyte.to_f).round(2)
    }
  end

  def sync_today_database_metrics_if_missing(today)
    return if CostMetric.exists?(date: today, metric_type: :daily_tokens)

    return unless BedrockQuery.exists?(created_at: today.all_day)

    SimpleMetricsService.update_database_metrics_only
  end

  def monthly_totals
    {
      total_tokens: CostMetric.total_for_month(:daily_tokens),
      total_cost: CostMetric.total_for_month(:daily_cost),
      total_queries: CostMetric.total_for_month(:daily_queries),
      avg_acu: CostMetric.avg_for_month(:aurora_acu_avg).round(2)
    }
  end
end
