# frozen_string_literal: true

class CreateKbDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :kb_documents do |t|
      t.string :s3_key, null: false
      t.string :display_name
      t.jsonb :aliases, null: false, default: []

      t.timestamps
    end
    add_index :kb_documents, :s3_key, unique: true
  end
end
