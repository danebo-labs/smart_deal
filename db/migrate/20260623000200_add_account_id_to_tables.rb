# frozen_string_literal: true

class AddAccountIdToTables < ActiveRecord::Migration[8.1]
  def up
    add_reference :users, :account, foreign_key: false, null: true, type: :bigint
    add_reference :kb_documents, :account, foreign_key: false, null: true, type: :bigint
    add_reference :conversation_sessions, :account, foreign_key: false, null: true, type: :bigint
    add_reference :web_manual_batches, :account, foreign_key: false, null: true, type: :bigint

    change_column :technician_documents, :account_id, :bigint, using: "account_id::bigint"
    add_foreign_key :technician_documents, :accounts, column: :account_id, name: :fk_td_account, validate: false
  end

  def down
    remove_foreign_key :technician_documents, name: :fk_td_account
    change_column :technician_documents, :account_id, :integer, using: "account_id::integer"

    remove_reference :web_manual_batches, :account, foreign_key: false
    remove_reference :conversation_sessions, :account, foreign_key: false
    remove_reference :kb_documents, :account, foreign_key: false
    remove_reference :users, :account, foreign_key: false
  end
end
