# frozen_string_literal: true

# Tenant-facing usage dashboard. Shows LLM consumption estimates only — no shared
# infra metrics (Aurora, S3 bucket). See docs/DASHBOARD.md for scope and multi-tenant roadmap.
class DashboardController < ApplicationController
  include MetricsHelper

  def index
    @current_metrics = current_metrics
    @monthly_totals = monthly_totals
    @chart_data = chart_data
    @kb_documents = KbDocument.order(created_at: :desc)
    @performance_metrics = performance_metrics
  end

  def metrics
    render json: {
      current: current_metrics,
      monthly: monthly_totals,
      chart: chart_data,
      updated_at: Time.current.iso8601
    }
  end

  private

  def chart_data
    DashboardCostChartService.new.call
  end

  def performance_metrics
    today_chat = BedrockQuery.query.where(created_at: Date.current.all_day)

    {
      avg_latency: today_chat.average(:latency_ms)&.round(0) || 0,
      fastest_query: today_chat.minimum(:latency_ms) || 0,
      slowest_query: today_chat.maximum(:latency_ms) || 0,
      total_queries: today_chat.count
    }
  end
end
