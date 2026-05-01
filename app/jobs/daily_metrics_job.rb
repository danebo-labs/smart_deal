# frozen_string_literal: true

class DailyMetricsJob < ApplicationJob
  queue_as :default

  def perform(date = Date.current)
    # Temporary observability: track executions for usage analysis.
    execution_context = caller_locations(1, 3).map(&:to_s).join(' <- ')
    Rails.logger.info("[DailyMetricsJob] Starting execution for #{date}")
    Rails.logger.info("[DailyMetricsJob] Execution context: #{execution_context}")
    Rails.logger.info("[DailyMetricsJob] Job ID: #{job_id}, Queue: #{queue_name}")

    start_time = Time.current
    SimpleMetricsService.new(date).save_daily_metrics
    # Refresh per-source breakdown + WhatsApp cache_hits / tokens_saved.
    # save_daily_metrics only writes 6 aggregates (tokens/cost/queries/aurora/s3*);
    # the dashboard refresh button would otherwise leave the home
    # footer detail metrics stale on a day with no incoming queries.
    SimpleMetricsService.update_database_metrics_only if date == Date.current
    duration = Time.current - start_time

    Rails.logger.info("[DailyMetricsJob] Completed successfully for #{date} in #{duration.round(2)}s")
  end
end
