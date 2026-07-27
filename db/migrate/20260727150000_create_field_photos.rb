# frozen_string_literal: true

class CreateFieldPhotos < ActiveRecord::Migration[8.1]
  def change
    create_table :field_photos do |t|
      t.references :account, null: false, foreign_key: true
      t.bigint  :user_id
      t.bigint  :conversation_session_id
      t.string  :sha256, null: false
      t.string  :s3_key_original, null: false
      t.string  :content_type, null: false
      t.integer :byte_size, null: false
      t.binary  :thumbnail_data
      t.string  :thumbnail_content_type
      t.integer :thumbnail_width
      t.integer :thumbnail_height
      t.timestamps
    end
    add_index :field_photos, [ :account_id, :sha256 ], unique: true
    add_index :field_photos, :created_at
  end
end
