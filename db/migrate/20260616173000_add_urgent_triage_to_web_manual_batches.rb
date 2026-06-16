# frozen_string_literal: true

class AddUrgentTriageToWebManualBatches < ActiveRecord::Migration[8.1]
  def change
    add_column :web_manual_batches, :urgent_status, :string
    add_column :web_manual_batches, :urgent_pages, :jsonb, default: [], null: false
    add_column :web_manual_batches, :urgent_chunks_s3_prefix, :string
    add_column :web_manual_batches, :urgent_error_message, :text
    add_column :web_manual_batches, :urgent_started_at, :datetime
    add_column :web_manual_batches, :urgent_completed_at, :datetime

    add_index :web_manual_batches, :urgent_status
  end
end
