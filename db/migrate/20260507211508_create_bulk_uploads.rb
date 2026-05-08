class CreateBulkUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :bulk_uploads do |t|
      t.references :user, null: true, foreign_key: false, index: true
      t.string :status, null: false, default: "pending"
      t.string :claude_batch_id
      t.string :sha256, null: false
      t.string :original_filename, null: false
      t.integer :asset_count, null: false, default: 0
      t.string :bedrock_ingestion_job_id
      t.text :error_message

      t.timestamps
    end

    add_index :bulk_uploads, :sha256, unique: true
    add_index :bulk_uploads, :status
  end
end
