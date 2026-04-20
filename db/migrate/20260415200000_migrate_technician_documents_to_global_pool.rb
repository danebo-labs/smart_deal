# frozen_string_literal: true

# Migrates technician_documents from per-technician scope to a global shared pool.
#
# Stage 0 (MVP): unique per canonical_name globally.
# Stage 1+:      account_id (nullable now, indexed later) enables per-tenant isolation.
#
# Steps:
#   1. Deduplicate existing rows — keep most recent per canonical_name.
#   2. Drop old [identifier, channel, canonical_name] unique index.
#   3. Drop old [identifier, channel, last_used_at] index.
#   4. Add account_id column (nullable) for future multi-tenancy.
#   5. Add global unique index on canonical_name.
#   6. Add global last_used_at index.
class MigrateTechnicianDocumentsToGlobalPool < ActiveRecord::Migration[8.1]
  def up
    # 1. Keep the most recently used row per canonical_name; delete the rest.
    execute <<~SQL.squish
      DELETE FROM technician_documents
      WHERE id NOT IN (
        SELECT id FROM (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY canonical_name
                   ORDER BY last_used_at DESC, id DESC
                 ) AS rn
          FROM technician_documents
        ) ranked
        WHERE rn = 1
      )
    SQL

    remove_index :technician_documents, name: "idx_tech_docs_unique"
    remove_index :technician_documents, name: "idx_tech_docs_recent"

    add_column :technician_documents, :account_id, :integer

    add_index :technician_documents, :canonical_name,
              unique: true, name: "idx_tech_docs_canonical_unique"
    add_index :technician_documents, :last_used_at,
              name: "idx_tech_docs_recent_global"
  end

  def down
    remove_index :technician_documents, name: "idx_tech_docs_canonical_unique"
    remove_index :technician_documents, name: "idx_tech_docs_recent_global"
    remove_column :technician_documents, :account_id

    add_index :technician_documents, %i[identifier channel canonical_name],
              unique: true, name: "idx_tech_docs_unique"
    add_index :technician_documents, %i[identifier channel last_used_at],
              name: "idx_tech_docs_recent"
  end
end
