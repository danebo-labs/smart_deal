# frozen_string_literal: true

# Replaces global unique indexes with account-scoped ones.
# disable_ddl_transaction! allows CONCURRENTLY index creation (non-blocking).
# New indexes are created before old ones are dropped so there is never a gap.
class ReplaceUniqueIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    # kb_documents: (account_id, s3_key) + (account_id, document_uid)
    add_index :kb_documents, %i[account_id s3_key],
              unique: true, algorithm: :concurrently,
              name: "idx_kb_documents_account_s3_key"
    add_index :kb_documents, %i[account_id document_uid],
              unique: true, algorithm: :concurrently,
              name: "idx_kb_documents_account_document_uid"
    remove_index :kb_documents, name: "index_kb_documents_on_s3_key"

    # technician_documents: (account_id, LOWER(canonical_name))
    execute "CREATE UNIQUE INDEX CONCURRENTLY idx_tech_docs_account_canonical_icase " \
            "ON technician_documents (account_id, LOWER(canonical_name))"
    remove_index :technician_documents, name: "idx_tech_docs_canonical_icase_unique"

    # web_manual_batches: (account_id, sha256, s3_key, ingestion_contract_version)
    add_index :web_manual_batches,
              %i[account_id sha256 s3_key ingestion_contract_version],
              unique: true, algorithm: :concurrently,
              name: "idx_web_manual_batches_account_contract"
    remove_index :web_manual_batches, name: "idx_web_manual_batches_unique_contract"

    # conversation_sessions: (account_id, identifier, channel)
    add_index :conversation_sessions, %i[account_id identifier channel],
              unique: true, algorithm: :concurrently,
              name: "idx_conversation_sessions_account_id_channel"
    remove_index :conversation_sessions,
                 name: "index_conversation_sessions_on_identifier_and_channel"
  end

  def down
    # kb_documents
    add_index :kb_documents, :s3_key,
              unique: true, algorithm: :concurrently,
              name: "index_kb_documents_on_s3_key"
    remove_index :kb_documents, name: "idx_kb_documents_account_s3_key"
    remove_index :kb_documents, name: "idx_kb_documents_account_document_uid"

    # technician_documents
    execute "CREATE UNIQUE INDEX CONCURRENTLY idx_tech_docs_canonical_icase_unique " \
            "ON technician_documents (LOWER(canonical_name))"
    remove_index :technician_documents, name: "idx_tech_docs_account_canonical_icase"

    # web_manual_batches
    add_index :web_manual_batches,
              %i[sha256 s3_key ingestion_contract_version],
              unique: true, algorithm: :concurrently,
              name: "idx_web_manual_batches_unique_contract"
    remove_index :web_manual_batches, name: "idx_web_manual_batches_account_contract"

    # conversation_sessions
    add_index :conversation_sessions, %i[identifier channel],
              unique: true, algorithm: :concurrently,
              name: "index_conversation_sessions_on_identifier_and_channel"
    remove_index :conversation_sessions, name: "idx_conversation_sessions_account_id_channel"
  end
end
