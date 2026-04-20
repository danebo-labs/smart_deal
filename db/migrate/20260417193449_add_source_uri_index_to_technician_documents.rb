# frozen_string_literal: true

# Adds a partial index on source_uri for fast deduplication lookups.
# Non-unique because source_uri can be blank when Bedrock returns 0 citations;
# only non-blank URIs are indexed (WHERE source_uri IS NOT NULL AND source_uri != '').
class AddSourceUriIndexToTechnicianDocuments < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE INDEX idx_tech_docs_source_uri
        ON technician_documents (source_uri)
        WHERE source_uri IS NOT NULL AND source_uri <> '';
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS idx_tech_docs_source_uri;"
  end
end
