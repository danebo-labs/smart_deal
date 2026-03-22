# frozen_string_literal: true

class CreateConversationSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :conversation_sessions do |t|
      t.string   :identifier,           null: false
      t.string   :channel,              null: false, default: "whatsapp"
      t.bigint   :user_id
      t.jsonb    :active_entities,      null: false, default: {}
      t.jsonb    :conversation_history, null: false, default: []
      t.jsonb    :current_procedure,    null: false, default: {}
      t.string   :session_status,       null: false, default: "active"
      t.datetime :expires_at,           null: false
      t.timestamps
    end

    add_index :conversation_sessions, [ :identifier, :channel ], unique: true
    add_index :conversation_sessions, :expires_at
    add_index :conversation_sessions, :user_id
    add_index :conversation_sessions, :active_entities,      using: :gin
    add_index :conversation_sessions, :conversation_history, using: :gin
  end
end
