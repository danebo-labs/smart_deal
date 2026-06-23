# frozen_string_literal: true

class AddDocumentUidToKbDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :kb_documents, :document_uid, :uuid
  end
end
