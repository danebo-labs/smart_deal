# frozen_string_literal: true

# Adds pg_trgm GIN indexes on KbDocument.display_name and the textified aliases
# array. KbDocumentResolver runs an OR-LIKE search over display_name + aliases
# on every RAG turn; without these indexes Postgres seq-scans kb_documents,
# which becomes the bottleneck once the catalog grows past a few hundred rows.
#
# Note: pg_trgm in RDS Postgres 13+ does NOT require superuser. If the role
# lacks CREATE EXTENSION privilege the migration fails with a clear message —
# the resolver still works (just slower without the index).
class AddTrigramIndexesToKbDocuments < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    enable_extension "pg_trgm" unless extension_enabled?("pg_trgm")

    add_index :kb_documents,
              "lower(display_name) gin_trgm_ops",
              using:    :gin,
              name:     "idx_kb_documents_display_name_trgm",
              algorithm: :concurrently,
              if_not_exists: true

    # GIN index over the lowercased JSON serialization of `aliases`. Postgres
    # rejects subqueries inside index expressions (no array_to_string(ARRAY(SELECT ...))),
    # so we index `aliases::text` — that yields a string like
    # `["sheave", "drum"]`, which still lets ILIKE '%sheave%' match. The
    # JSON brackets/quotes can produce false-positives at the SQL level
    # (e.g. searching for `]` would always match), but the resolver's Ruby
    # post-filter (\b word-boundary regex) discards anything that's not a
    # real token match. Net effect: index is hit, semantics preserved.
    execute <<~SQL.squish
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_kb_documents_aliases_text_trgm
      ON kb_documents USING gin (lower(aliases::text) gin_trgm_ops)
    SQL
  end

  def down
    remove_index :kb_documents, name: "idx_kb_documents_display_name_trgm", if_exists: true
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_kb_documents_aliases_text_trgm"
  end
end
