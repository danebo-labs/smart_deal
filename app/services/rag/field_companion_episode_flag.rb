# frozen_string_literal: true

module Rag
# Switch for writing conversation_sessions.active_episode.
# Absent or blank enables it. The explicit string "false" is the kill switch.
# Any other string stays off. Session context reads the column for the
# field-problem prompt when this flag and FieldCompanionTurnFlag are both on.
# Retrieval URIs come from active_entities, not from the episode.
module FieldCompanionEpisodeFlag
  module_function

  def enabled?
    value = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    return true if value.nil? || value.strip.empty?

    value == "true"
  end
end
end
