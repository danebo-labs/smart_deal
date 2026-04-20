# frozen_string_literal: true

# Replaces the case-sensitive unique index on canonical_name with a functional
# LOWER(canonical_name) index. This prevents duplicates when Haiku returns the
# same document name with different capitalisation across independent RAG calls
# (e.g. "Electromagnetic disc brake" vs "Electromagnetic Disc Brake").
class ReplaceCanonicalNameIndexWithCaseInsensitive < ActiveRecord::Migration[8.1]
  def up
    remove_index :technician_documents, name: "idx_tech_docs_canonical_unique", if_exists: true

    execute <<~SQL.squish
      CREATE UNIQUE INDEX idx_tech_docs_canonical_icase_unique
        ON technician_documents (LOWER(canonical_name));
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS idx_tech_docs_canonical_icase_unique;"

    add_index :technician_documents, :canonical_name,
              unique: true, name: "idx_tech_docs_canonical_unique"
  end
end
