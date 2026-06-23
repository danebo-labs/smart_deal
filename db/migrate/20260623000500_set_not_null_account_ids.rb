# frozen_string_literal: true

# Pre-condition: SELECT count(*) FROM <table> WHERE account_id IS NULL = 0 for all
# tables (confirmed by backfill:account_ids + backfill:document_uids tasks).
class SetNotNullAccountIds < ActiveRecord::Migration[8.1]
  def up
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
