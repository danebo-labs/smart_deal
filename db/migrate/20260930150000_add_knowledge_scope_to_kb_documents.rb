# frozen_string_literal: true

# Document-level knowledge scope. Every existing row stays tenant_private.
# danebo_general is an explicit later write through KnowledgeScopeChange.
# No DB enum: a string plus a check constraint rolls back cleanly.
class AddKnowledgeScopeToKbDocuments < ActiveRecord::Migration[8.1]
  def up
    add_column :kb_documents, :knowledge_scope, :string, null: false, default: "tenant_private"
    add_check_constraint :kb_documents,
      "knowledge_scope IN ('tenant_private', 'danebo_general')",
      name: "chk_kb_documents_knowledge_scope"

    # Pin authorization and suggestion resolve rows by s3_key and document_uid.
    # Those lookups are not prefixed by account_id, so the account-scoped
    # unique indexes cannot serve them.
    add_index :kb_documents, :s3_key, name: "idx_kb_documents_s3_key"
    add_index :kb_documents, :document_uid, name: "idx_kb_documents_document_uid"
    add_index :kb_documents, :id,
      where: "knowledge_scope = 'danebo_general'",
      name: "idx_kb_documents_danebo_general"

    leftover = select_value(<<~SQL.squish)
      SELECT COUNT(*) FROM kb_documents
      WHERE knowledge_scope IS DISTINCT FROM 'tenant_private'
    SQL
    if leftover.to_i != 0
      raise "knowledge_scope backfill left #{leftover} rows outside tenant_private"
    end

    # Explicit source-account mark. Slug and historical pilot membership do
    # not set it. Existing accounts stay false.
    add_column :accounts, :danebo_controlled, :boolean, null: false, default: false

    create_table :knowledge_scope_changes do |t|
      t.references :kb_document, null: false, foreign_key: true, index: true
      t.string :from_scope, null: false
      t.string :to_scope, null: false
      t.string :actor, null: false
      t.text :reason, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :knowledge_scope_changes,
      "from_scope IN ('tenant_private', 'danebo_general')",
      name: "chk_knowledge_scope_changes_from_scope"
    add_check_constraint :knowledge_scope_changes,
      "to_scope IN ('tenant_private', 'danebo_general')",
      name: "chk_knowledge_scope_changes_to_scope"
  end

  def down
    execute <<~SQL.squish
      DROP TRIGGER IF EXISTS knowledge_scope_changes_append_only ON knowledge_scope_changes;
      DROP FUNCTION IF EXISTS knowledge_scope_changes_append_only();
    SQL
    drop_table :knowledge_scope_changes
    remove_column :accounts, :danebo_controlled
    remove_index :kb_documents, name: "idx_kb_documents_danebo_general"
    remove_index :kb_documents, name: "idx_kb_documents_document_uid"
    remove_index :kb_documents, name: "idx_kb_documents_s3_key"
    remove_check_constraint :kb_documents, name: "chk_kb_documents_knowledge_scope"
    remove_column :kb_documents, :knowledge_scope
  end
end
