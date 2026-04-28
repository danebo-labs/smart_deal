# frozen_string_literal: true

# Builds the session context string injected into the Bedrock generation prompt.
# Includes: active documents/images block + recent conversation history block.
class SessionContextBuilder
  # An entity counts as a "fresh upload" when it was registered as an image
  # upload very recently AND has not yet driven any answer. The technician's
  # first identification query right after the upload should bias toward this
  # entity — we surface a hint to Haiku (Session Focus header) and the WA
  # delivery layer pre-pends a small banner. Retrieval is NOT narrowed; we
  # keep the multi-doc safety net (false positives are recoverable, false
  # negatives leave the tech with nothing).
  FRESH_UPLOAD_WINDOW = 120.seconds

  # @param session [ConversationSession, nil]
  # @return [String] context block to append to generation prompt (empty string when nothing)
  def self.build(session)
    return "" if session.nil?

    parts = []

    if session.has_active_entities?
      ordered_entities = entities_sorted_by_recency(session)
      fresh_key, _    = fresh_upload_pair(session)
      lines           = []

      ordered_entities.each do |key, meta|
        type    = meta["source"] == "image_upload" ? "image" : "document"
        aliases = Array(meta["aliases"]).compact_blank
        summary = meta["first_answer_summary"]

        alias_note   = aliases.any? ? "  (also: #{aliases.join(', ')})" : ""
        summary_note = summary.present? ? "\n    Summary: #{summary}" : ""
        fresh_tag    = (key == fresh_key ? " 📸 (just uploaded — prefer this when the question is identification or about \"this image\")" : "")
        lines << "- [#{type}] #{key}#{fresh_tag}#{alias_note}#{summary_note}"
      end

      parts << <<~BLOCK.strip
        ## Session Focus
        The following documents/images have been referenced or uploaded during this conversation, ordered most-recent first.
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
  #
  # Scope: ONLY active_entities of the current conversation session. We do NOT
  # pull from TechnicianDocument anymore — the filter must match what the user
  # (and Haiku via Session Focus) actually see in the live conversation. Queries
  # that reference documents outside the session are handled by the bypass in
  # BedrockRagService#query_names_different_document? (explicit name detection)
  # and the no-results retry-without-filter fallback.
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

  # Returns the freshest image-upload entity that has not yet driven an answer,
  # or nil. Used by the WhatsApp delivery layer to render the "📸 just uploaded"
  # banner above the first message after a media ingest. Retrieval continues to
  # span the full session working set — this is presentation + Haiku-bias only.
  # @param session [ConversationSession, nil]
  # @return [Hash, nil] { canonical_name:, aliases:, source_uri:, added_at: } or nil
  def self.fresh_upload_entity(session)
    key, meta = fresh_upload_pair(session)
    return nil if key.nil?

    {
      canonical_name: key,
      aliases:        Array(meta["aliases"]).compact_blank,
      source_uri:     meta["source_uri"],
      added_at:       meta["added_at"]
    }
  end

  # @return [Array(String, Hash), nil] [key, meta] of the freshest qualifying
  #   image_upload entity or nil
  def self.fresh_upload_pair(session)
    return nil if session.nil? || session.active_entities.blank?

    cutoff = Time.current - FRESH_UPLOAD_WINDOW
    candidates = session.active_entities.select do |_, meta|
      next false unless meta["source"].to_s == "image_upload"
      next false unless meta["first_answer_summary"].to_s.strip.empty?

      ts = parse_added_at(meta["added_at"])
      ts.present? && ts >= cutoff
    end
    return nil if candidates.empty?

    candidates.max_by { |_, meta| parse_added_at(meta["added_at"]).to_i }
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
