# frozen_string_literal: true

class DashboardController < ApplicationController
  include MetricsHelper

  def index
    @current_metrics = current_metrics
    @monthly_totals = monthly_totals
    @last_month_totals = last_month_totals
    @chart_data = chart_data
    s3 = S3DocumentsService.new
    @s3_bucket_name = s3.bucket_name
    @kb_doc_index = KbDocument.all.index_by { |kb| KbDocument.object_key_for_match(kb.s3_key) }
    @s3_documents_list = KbDocument.sort_s3_documents_by_kb_created_at(s3.list_documents, @kb_doc_index)
    @performance_metrics = performance_metrics
  end

  def metrics
    render json: {
      current: current_metrics,
      monthly: monthly_totals,
      last_month: last_month_totals,
      chart: chart_data,
      updated_at: Time.current.iso8601
    }
  end

  def refresh
    DailyMetricsJob.perform_later(Date.current)
    redirect_to dashboard_path, notice: 'Métricas actualizándose...'
  end

  private

  def last_month_totals
    {
      total_tokens: CostMetric.total_for_last_month(:daily_tokens),
      total_cost: CostMetric.total_for_last_month(:daily_cost),
      total_queries: CostMetric.total_for_last_month(:daily_queries),
      avg_acu: CostMetric.avg_for_last_month(:aurora_acu_avg).round(2)
    }
  end

  def chart_data
    last_30 = CostMetric.last_30_days
                        .where(metric_type: :daily_cost)
                        .order(:date)
                        .pluck(:date, :value)

    {
      labels: last_30.map { |d, _| d.strftime('%m/%d') },
      values: last_30.map { |_, v| v.to_f }
    }
  end

  def performance_metrics
    today_queries = BedrockQuery.where(created_at: Date.current.all_day)

    {
      avg_latency: today_queries.average(:latency_ms)&.round(0) || 0,
      fastest_query: today_queries.minimum(:latency_ms) || 0,
      slowest_query: today_queries.maximum(:latency_ms) || 0,
      total_queries: today_queries.count
    }
  end
end
