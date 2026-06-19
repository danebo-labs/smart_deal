# frozen_string_literal: true

# Persists authoritative Bedrock spend for one UTC day from S3 invocation logs
# into bedrock_daily_costs. Idempotent: fully replaces the day's rows each run.
# Scheduled daily for "yesterday UTC" (logs are complete + delivered by then);
# also runnable for any past date via the bedrock:reconcile_persist rake task.
class ReconcileBedrockCostJob < ApplicationJob
  queue_as :default

  # @param date_str [String, nil] "YYYY-MM-DD" UTC date. nil => yesterday UTC.
  # @return [Hash] the reconciler report (for the rake task to print)
  def perform(date_str = nil)
    date   = date_str.present? ? Date.parse(date_str) : (Time.now.utc.to_date - 1)
    report = BedrockInvocationLogReconciler.new.day(date)

    now = Time.current
    rows = report[:rows].map do |r|
      {
        utc_date:           date,
        model_id:           r[:model_id],
        invocation_count:   r[:count],
        input_tokens:       r[:input_tokens],
        output_tokens:      r[:output_tokens],
        cache_read_tokens:  r[:cache_read_tokens],
        cache_write_tokens: r[:cache_write_tokens],
        cost_usd:           r[:cost],
        reconciled_at:      now,
        created_at:         now,
        updated_at:         now
      }
    end

    ActiveRecord::Base.transaction do
      BedrockDailyCost.where(utc_date: date).delete_all
      BedrockDailyCost.insert_all(rows) if rows.any?
    end

    Rails.logger.info(
      "[ReconcileBedrockCostJob] #{date} reconciled: " \
      "$#{report[:total_cost]} across #{rows.size} model(s)"
    )
    report
  rescue StandardError => e
    Rails.logger.error(
      "[ReconcileBedrockCostJob] date=#{date_str || 'yesterday'} failed: #{e.class}: #{e.message}"
    )
    raise
  end
end
