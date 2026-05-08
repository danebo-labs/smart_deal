class CreateBulkUploadAssets < ActiveRecord::Migration[8.1]
  def change
    create_table :bulk_upload_assets do |t|
      t.references :bulk_upload, null: false, foreign_key: false, index: true
      t.references :kb_document, null: true, foreign_key: false, index: true
      t.string :custom_id, null: false
      t.string :sha256, null: false
      t.string :s3_key
      t.string :chunks_s3_prefix
      t.string :filename, null: false
      t.string :content_type
      t.string :status, null: false, default: "pending"
      t.string :canonical_name
      t.jsonb :aliases, null: false, default: []
      t.integer :chunks_count
      t.integer :claude_input_tokens
      t.integer :claude_output_tokens
      t.text :error_message

      t.timestamps
    end

    add_index :bulk_upload_assets, :custom_id, unique: true
    add_index :bulk_upload_assets, [ :bulk_upload_id, :custom_id ]
    add_index :bulk_upload_assets, :status
  end
end
