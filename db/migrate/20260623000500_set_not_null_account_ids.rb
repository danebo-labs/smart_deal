# frozen_string_literal: true

# Embeds the backfill so this migration is safe to run on production without
# a separate pre-step. Uses raw SQL to avoid model coupling.
class SetNotNullAccountIds < ActiveRecord::Migration[8.1]
  def up
    # Ensure the legacy account exists before backfilling.
    execute <<~SQL.squish
      INSERT INTO accounts (slug, created_at, updated_at)
      VALUES ('danebo-legacy', NOW(), NOW())
      ON CONFLICT (slug) DO NOTHING
    SQL

    legacy_id_result = execute("SELECT id FROM accounts WHERE slug = 'danebo-legacy' LIMIT 1")
    legacy_id = legacy_id_result.first["id"]

    # Backfill NULL account_ids on all five tables.
    %w[users kb_documents conversation_sessions web_manual_batches technician_documents].each do |table|
      execute("UPDATE #{table} SET account_id = #{legacy_id} WHERE account_id IS NULL")
    end

    # Backfill NULL document_uid on kb_documents.
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")
    execute("UPDATE kb_documents SET document_uid = gen_random_uuid() WHERE document_uid IS NULL")

    change_column_null :users,                 :account_id,   false
    change_column_null :kb_documents,          :account_id,   false
    change_column_null :kb_documents,          :document_uid, false
    change_column_null :conversation_sessions, :account_id,   false
    change_column_null :web_manual_batches,    :account_id,   false
    change_column_null :technician_documents,  :account_id,   false
  end

  def down
    change_column_null :users,                 :account_id,   true
    change_column_null :kb_documents,          :account_id,   true
    change_column_null :kb_documents,          :document_uid, true
    change_column_null :conversation_sessions, :account_id,   true
    change_column_null :web_manual_batches,    :account_id,   true
    change_column_null :technician_documents,  :account_id,   true
  end
end
