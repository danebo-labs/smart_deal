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
        summary = meta["first_answer_summary"]

        alias_note   = aliases.any? ? "  (also: #{aliases.join(', ')})" : ""
        summary_note = summary.present? ? "\n    Summary: #{summary}" : ""
        lines << "- [#{type}] #{key}#{alias_note}#{summary_note}"
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

  # Returns S3 URIs of all active entities that have a known source_uri.
  # Used by BedrockRagService to scope KB retrieval to session documents.
  # Rejects fabricated URIs (e.g. s3://unknown-bucket/...) that Haiku sometimes
  # invents when it can't find the real sourceUrl in the chunk metadata.
  FABRICATED_URI_PATTERN = %r{\As3://(unknown|unknown-bucket|placeholder|no[_-]?bucket)/}i.freeze

  def self.entity_s3_uris(session)
    return [] if session.nil?

    from_session = session.active_entities.values.filter_map { |meta| meta["source_uri"] }
    from_db      = TechnicianDocument.where.not(source_uri: [ nil, "" ]).pluck(:source_uri)

    (from_session + from_db)
      .select { |uri| uri.start_with?("s3://") }
      .reject { |uri| uri.match?(FABRICATED_URI_PATTERN) }
      .reject { |uri| uri.include?("PIPELINE_INJECTED") }
      .uniq
  end
end
