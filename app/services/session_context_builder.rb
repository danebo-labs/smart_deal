# frozen_string_literal: true

# Builds the session context string injected into the Bedrock generation prompt.
# Includes: active documents/images block + recent conversation history block.
class SessionContextBuilder
  # @param session [ConversationSession, nil]
  # @return [String] context block to append to generation prompt (empty string when nothing)
  def self.build(session)
    return "" if session.nil?

    parts = []

    if session.has_active_entities?
      entities = session.active_entities
      lines    = []

      entities.each do |key, meta|
        type    = meta["source"] == "image_upload" ? "image" : "document"
        aliases = Array(meta["aliases"]).compact_blank

        alias_note = aliases.any? ? "  (also: #{aliases.join(', ')})" : ""
        lines << "- [#{type}] #{key}#{alias_note}"
      end

      parts << <<~BLOCK.strip
        ## Session Focus
        The following documents/images have been referenced or uploaded during this conversation.
        When the user refers to "this document", "that image", "the same file", or uses ANY of the listed aliases, assume they mean one of these:
        #{lines.join("\n")}
      BLOCK
    end

    history = session.recent_history_for_prompt(turns: 3)
    if history.any?
      history_lines = history.map { |h| "#{h[:role].capitalize}: #{h[:content]}" }.join("\n")
      parts << <<~BLOCK.strip
        ## Recent Conversation
        #{history_lines}
      BLOCK
    end

    parts.join("\n\n")
  end
end
