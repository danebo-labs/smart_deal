# frozen_string_literal: true

# Builds the session context string injected into the Bedrock generation prompt.
# Includes: pinned documents block + recent conversation history block + session
# discipline directive (when both coexist).
#
# active_entities now contains ONLY user-pinned documents (UI checkbox or
# upload auto-pin). Haiku citations never register here.
class SessionContextBuilder
  # @param session [ConversationSession, nil]
  # @return [String] context block to append to generation prompt (empty string when nothing)
  def self.build(session)
    return "" if session.nil?

    parts = []

    if session.has_active_entities?
      ordered_entities = entities_sorted_by_recency(session)
      lines            = []

      ordered_entities.each do |key, meta|
        type    = meta["source"] == "image_upload" ? "image" : "document"
        aliases = Array(meta["aliases"]).compact_blank
        summary = meta["first_answer_summary"]

        alias_note   = aliases.any? ? "  (also: #{aliases.join(', ')})" : ""
        summary_note = summary.present? ? "\n    Summary: #{summary}" : ""
        lines << "- [#{type}] #{key}#{alias_note}#{summary_note}"
      end

      parts << <<~BLOCK.strip
        ## Session Focus
        The technician has explicitly pinned the following documents/images for this conversation. These are the sources you should ground your answer in. When the user refers to "this document", "that image", "the same file", or uses ANY of the listed aliases, assume they mean one of these:
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

    if session.has_active_entities? && history.any?
      parts << <<~BLOCK.strip
        ## Session Discipline
        If documents mentioned in 'Recent Conversation' are NOT listed in 'Session Focus' above, the user has unpinned them — treat those documents as out of scope for the current question. Resolve pronouns and topical references using ONLY documents in Session Focus. If the current question is asking specifically about an out-of-scope document, say so plainly and offer to re-pin it.
      BLOCK
    end

    parts.join("\n\n")
  end

  # Returns S3 URIs of all active entities (= pinned docs) that have a known source_uri.
  # Used by BedrockRagService to scope KB retrieval to pinned documents.
  FABRICATED_URI_PATTERN = %r{\As3://(unknown|unknown-bucket|placeholder|no[_-]?bucket)/}i.freeze

  def self.entity_s3_uris(session)
    return [] if session.nil?

    session.active_entities.values
      .filter_map { |meta| meta["source_uri"] }
      .select { |uri| uri.start_with?("s3://") }
      .reject { |uri| uri.match?(FABRICATED_URI_PATTERN) }
      .reject { |uri| uri.include?("PIPELINE_INJECTED") }
      .uniq
  end

  # Active entities sorted by `added_at` desc (most-recent first). Falls back
  # to the original Hash insertion order for entries without a parseable
  # timestamp so legacy data keeps working.
  def self.entities_sorted_by_recency(session)
    indexed = session.active_entities.each_with_index.map do |(key, meta), idx|
      [ key, meta, parse_added_at(meta["added_at"]), idx ]
    end
    indexed
      .sort_by { |_, _, ts, idx| [ -(ts ? ts.to_i : 0), idx ] }
      .map { |key, meta, _, _| [ key, meta ] }
      .to_h
  end

  def self.parse_added_at(value)
    return nil if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
