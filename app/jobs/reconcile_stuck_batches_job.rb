# frozen_string_literal: true

# Watchdog for batches that entered `submitting` but crashed before persisting
# `claude_batch_id`. These rows would block SubmitManualBatchJob's idempotency
# lock forever. The job transitions them to `submission_unknown` for manual
# reconciliation against Anthropic — no auto-retry.
#
# Scheduled every 15 min via config/recurring.yml.
# Manual: bin/rails web_manual_batches:reconcile_stuck
class ReconcileStuckBatchesJob < ApplicationJob
  queue_as :default

  def perform
    cutoff     = ENV.fetch("WEB_MANUAL_BATCH_SUBMITTING_TIMEOUT", "30").to_i.minutes.ago
    count      = 0

    WebManualBatch
      .where(status: "submitting", claude_batch_id: nil)
      .where(updated_at: ...cutoff)
      .find_each do |batch|
        batch.update_columns(status: "submission_unknown")
        Rails.logger.warn(
          "ReconcileStuckBatchesJob: id=#{batch.id} #{batch.filename} → " \
          "submission_unknown (requires manual reconciliation with Anthropic)"
        )
        count += 1
      end

    Rails.logger.info("ReconcileStuckBatchesJob: #{count} stuck batch(es) → submission_unknown")
  end
end
