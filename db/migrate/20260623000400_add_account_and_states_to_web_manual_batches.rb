# frozen_string_literal: true

class AddAccountAndStatesToWebManualBatches < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :web_manual_batches,
      "status IN ('pending', 'submitting', 'submitted', 'submission_unknown', 'in_progress', 'parsing', 'parsed', 'syncing', 'complete', 'failed')",
      name: "chk_web_manual_batches_status"
  end
end
