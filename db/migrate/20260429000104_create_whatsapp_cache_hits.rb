# frozen_string_literal: true

class CreateWhatsappCacheHits < ActiveRecord::Migration[8.1]
  def change
    create_table :whatsapp_cache_hits do |t|
      t.string  :recipient,            null: false
      t.string  :route,                null: false
      t.integer :tokens_saved_estimate

      t.timestamps
    end

    add_index :whatsapp_cache_hits, [ :recipient, :created_at ]
    add_index :whatsapp_cache_hits, [ :route,     :created_at ]
  end
end
