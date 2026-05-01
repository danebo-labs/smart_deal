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

    CostMetric.daily_snapshot(today)
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
