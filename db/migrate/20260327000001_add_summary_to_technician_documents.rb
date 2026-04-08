# frozen_string_literal: true

class AddSummaryToTechnicianDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :technician_documents, :first_answer_summary, :string
  end
end
