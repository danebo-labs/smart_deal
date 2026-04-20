class AddSizeBytesToKbDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :kb_documents, :size_bytes, :bigint
  end
end
