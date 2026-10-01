# frozen_string_literal: true

class AddDocumentFocusToConversationSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :conversation_sessions, :document_focus, :jsonb, null: false, default: []

    ConversationSession.reset_column_information
    ConversationSession.where.not(channel: "whatsapp").find_each do |session|
      next if session.active_entities.blank?

      entries = ConversationSession.document_focus_from_legacy(session.active_entities, account: session.account)
      next if entries.empty?

      session.update_columns(document_focus: entries) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    remove_column :conversation_sessions, :document_focus
  end
end
