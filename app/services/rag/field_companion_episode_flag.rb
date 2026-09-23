# frozen_string_literal: true

module Rag
  # Shadow switch for writing conversation_sessions.active_episode.
  # Default OFF. Nothing reads the column for context or retrieval.
  module FieldCompanionEpisodeFlag
    module_function

    def enabled?
      ENV["FIELD_COMPANION_EPISODE_ENABLED"] == "true"
    end
  end
end
