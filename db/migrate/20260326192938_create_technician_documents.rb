class CreateTechnicianDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :technician_documents do |t|
      t.string   :identifier,        null: false
      t.string   :channel,           null: false, default: "whatsapp"
      t.string   :canonical_name,    null: false
      t.jsonb    :aliases,           null: false, default: []
      t.string   :wa_filename
      t.string   :source_uri
      t.string   :doc_type
      t.integer  :interaction_count, null: false, default: 1
      t.datetime :last_used_at,      null: false
      t.timestamps
    end

    add_index :technician_documents,
              [ :identifier, :channel, :canonical_name ],
              unique: true,
              name: "idx_tech_docs_unique"

    add_index :technician_documents,
              [ :identifier, :channel, :last_used_at ],
              name: "idx_tech_docs_recent"
  end
end
