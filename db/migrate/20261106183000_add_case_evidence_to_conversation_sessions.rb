# frozen_string_literal: true

class AddCaseEvidenceToConversationSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :conversation_sessions, :case_evidence, :jsonb, default: {}, null: false
  end
end
