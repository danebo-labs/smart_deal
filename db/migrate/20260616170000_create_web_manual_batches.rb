# frozen_string_literal: true

class CreateWebManualBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :web_manual_batches do |t|
      t.string :s3_key, null: false
      t.string :filename, null: false
      t.string :sha256, null: false
      t.string :content_type, default: "application/pdf", null: false
      t.string :ingestion_contract_version, null: false
      t.string :claude_batch_id
      t.string :status, default: "pending", null: false
      t.jsonb :page_customs, default: {}, null: false
      t.jsonb :kept_pages, default: [], null: false
      t.integer :total_pages
      t.bigint :kb_document_id
      t.bigint :conv_session_id
      t.string :locale
      t.string :canonical_name
      t.jsonb :aliases, default: [], null: false
      t.integer :chunks_count
      t.string :chunks_s3_prefix
      t.text :error_message
      t.datetime :submitted_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :web_manual_batches,
              [ :sha256, :s3_key, :ingestion_contract_version ],
              unique: true,
              name: "idx_web_manual_batches_unique_contract"
    add_index :web_manual_batches, :claude_batch_id, unique: true
    add_index :web_manual_batches, :status
    add_index :web_manual_batches, :kb_document_id
    add_index :web_manual_batches, :conv_session_id
  end
end
