# frozen_string_literal: true

# The project does not use DB-level foreign key constraints (see schema.rb).
# Drop the FK added by CreateKbDocumentThumbnails so the test DB user
# (non-superuser) doesn't hit PG::InsufficientPrivilege on pg_constraint.
# App-layer integrity is enforced by belongs_to / has_one associations.
class RemoveKbDocumentThumbnailsForeignKey < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :kb_document_thumbnails, :kb_documents
  end

  def down
    add_foreign_key :kb_document_thumbnails, :kb_documents
  end
end
