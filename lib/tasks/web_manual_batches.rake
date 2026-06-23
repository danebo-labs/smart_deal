# frozen_string_literal: true

namespace :web_manual_batches do
  desc "Transition submitting batches with no claude_batch_id older than WEB_MANUAL_BATCH_SUBMITTING_TIMEOUT to submission_unknown"
  task reconcile_stuck: :environment do
    ReconcileStuckBatchesJob.perform_now
  end
end
