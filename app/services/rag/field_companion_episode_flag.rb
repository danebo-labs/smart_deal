# frozen_string_literal: true

module Rag
  # Switch for writing conversation_sessions.active_episode. Default OFF:
  # ENV must be "true".
  # Session context reads the column for the field-problem prompt when this
  # flag and FieldCompanionTurnFlag are both on. Retrieval URIs come from
  # active_entities, not from the episode.
  module FieldCompanionEpisodeFlag
    module_function

    def enabled?
      ENV["FIELD_COMPANION_EPISODE_ENABLED"] == "true"
    end
  end
end
