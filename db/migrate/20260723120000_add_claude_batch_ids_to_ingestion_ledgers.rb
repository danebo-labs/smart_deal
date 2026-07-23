# frozen_string_literal: true

class AddClaudeBatchIdsToIngestionLedgers < ActiveRecord::Migration[8.1]
  def change
    add_column :web_manual_batches, :claude_batch_ids, :jsonb, default: [], null: false
    add_column :bulk_uploads, :claude_batch_ids, :jsonb, default: [], null: false
  end
end
