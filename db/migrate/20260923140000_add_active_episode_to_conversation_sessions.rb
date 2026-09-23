# frozen_string_literal: true

class AddActiveEpisodeToConversationSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :conversation_sessions, :active_episode, :jsonb, null: false, default: {}
  end
end
