# frozen_string_literal: true

# Query-volume view for the demo: same underlying activity as /dashboard, but
# counts only — no USD, no tokens. Kept as a page fully separate from
# DashboardController so it is structurally impossible to leak a price here
# (it never touches CostMetric or BedrockQuery#cost).
# Guarded by ENV["ACTIVITY_DASHBOARD_ENABLED"] (ActivityDashboardFlag): with
# the flag off, the page 404s and /dashboard keeps rendering costs as before.
class ActivityController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_activity_dashboard_enabled!

  def index
    @chart_data = AccountActivityChartService.new(account_id: current_account.id).call
    @kb_documents = KbDocument.where(account_id: current_account.id).order(created_at: :desc)
    @performance_metrics = performance_metrics
  end

  private

  def ensure_activity_dashboard_enabled!
    head :not_found unless ActivityDashboardFlag.enabled?
  end

  def performance_metrics
    count, avg_latency, min_latency, max_latency =
      BedrockQuery.query
                  .where(account_id: current_account.id, created_at: Date.current.all_day)
                  .pick(Arel.sql("COUNT(*), AVG(latency_ms), MIN(latency_ms), MAX(latency_ms)"))

    {
      total_queries: count,
      avg_latency: avg_latency&.round(0) || 0,
      fastest_query: min_latency || 0,
      slowest_query: max_latency || 0
    }
  end
end
