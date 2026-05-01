# frozen_string_literal: true

# Stores a small JPEG thumbnail (≤15 KB, 88 px wide) per image-type KbDocument.
# Persisted as BLOB so the mobile docs panel can render an inline data URL with
# zero extra HTTP round-trips — critical for technicians on flaky connectivity.
# Stored in a separate table to avoid inflating KbDocument SELECT * queries.
class CreateKbDocumentThumbnails < ActiveRecord::Migration[8.1]
  def change
    create_table :kb_document_thumbnails do |t|
      t.references :kb_document, null: false, foreign_key: true, index: { unique: true }
      t.binary  :data,         null: false
      t.string  :content_type, null: false, default: "image/jpeg"
      t.integer :width
      t.integer :height
      t.integer :byte_size
      t.timestamps
    end
  end
end
