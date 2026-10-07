# frozen_string_literal: true

# Builds the session context string injected into the Bedrock generation prompt.
# Includes: pinned documents block + recent conversation history block + session
# discipline directive (when both coexist).
#
# When both field-companion flags are on, a current web episode is prepended as
# technician-stated job state. That block is not documentary evidence.
#
# Web focus is conversation_sessions.document_focus. WhatsApp still reads
# active_entities. Aliases and image/document come from KbDocument on web.
class SessionContextBuilder
  # Hard cap on session context injected into the generation prompt.
  # Prevents runaway entity lists + long histories from blowing the input budget.
  # ~500 tokens at Haiku tokenization rates; covers ~3 pinned docs + 3 turns comfortably.
  MAX_CONTEXT_CHARS = 2000
  MAX_ALIASES_PER_ENTITY = 5
  MAX_PROBLEM_CHARS = 600
  PROBLEM_HEADER = "## Active Field Problem"
  PROBLEM_FOOTER = "Not a manual. Procedures, values, terminals, and code meanings come from retrieved evidence. Ignore for other equipment."
  UNKNOWN_FACT_LINE = {
    "manufacturer" => "Manufacturer: technician confirmed it is unknown; do not ask for it again.",
    "model" => "Model: technician confirmed it is unknown; do not ask for it again.",
    "controller" => "Controller: technician confirmed it is unknown; do not ask for it again."
  }.freeze
  ABSENT_FAULT_LINE = "Fault code: technician confirmed no code is shown; do not ask for it again."
  FACT_LABEL = {
    "manufacturer" => "Manufacturer",
    "model" => "Model",
    "controller" => "Controller",
    "fault_code" => "Fault code"
  }.freeze

  # @param session [ConversationSession, nil]
  # @return [String] context block to append to generation prompt (empty string when nothing)
  def self.build(session, active_photo_context: nil)
    return "" if session.nil?

    trace = { truncated: false }
    text = assemble_context(session, active_photo_context, trace)
    mark_context_truncated(session, trace[:truncated])
    record_context_fit(text, trace)
    text
  end

  def self.assemble_context(session, active_photo_context, trace)
    parts = []

    if focused_for_prompt?(session)
      lines = focus_prompt_lines(session)

      parts << <<~BLOCK.strip
        ## Session Focus
        The technician has explicitly pinned the following documents/images for this conversation. These are the sources you should ground your answer in. When the user refers to "this document", "that image", "the same file", or uses ANY of the listed aliases, assume they mean one of these:
        #{lines.join("\n")}
      BLOCK
    end

    history =
      if Rag::EpisodeScopeFlag.enabled? && session.respond_to?(:episode_user_messages)
        users = session.episode_user_messages.map { |content| { role: "user", content: content } }
        last  = session.last_assistant_message
        users + (last ? [ { role: "assistant", content: last.truncate(200) } ] : [])
      else
        session.recent_history_for_prompt(turns: 3)
      end
    if history.any?
      history_lines = history.map { |h| "#{h[:role].capitalize}: #{h[:content]}" }.join("\n")
      parts << <<~BLOCK.strip
        ## Recent Conversation
        #{history_lines}
      BLOCK
    end

    if focused_for_prompt?(session) && history.any?
      parts << <<~BLOCK.strip
        ## Session Discipline
        If documents mentioned in 'Recent Conversation' are NOT listed in 'Session Focus' above, the user has unpinned them — treat those documents as out of scope for the current question. Resolve pronouns and topical references using ONLY documents in Session Focus. If the current question is asking specifically about an out-of-scope document, say so plainly and offer to re-pin it.
      BLOCK
    end

    result = parts.join("\n\n")
    problem = field_problem_block(session, trace: trace)
    photo = active_photo_block(session, active_photo_context)
    if photo.empty?
      if problem.empty?
        if result.length > MAX_CONTEXT_CHARS
          trace[:truncated] = true
          note_omission(trace, "session_context", result[MAX_CONTEXT_CHARS..])
          result[0, MAX_CONTEXT_CHARS]
        else
          result
        end
      else
        compose_with_problem(problem, result, trace)
      end
    else
      compose_with_photo(problem, photo, result, trace)
    end
  end
  private_class_method :assemble_context

  def self.mark_context_truncated(session, truncated)
    return unless session.respond_to?(:context_truncated=)

    session.context_truncated = truncated == true
  end
  private_class_method :mark_context_truncated

  # Technician-stated job state for the current web episode.
  # Empty unless both companion flags are on and the episode is still current.
  # The block never includes pinned documents, summaries, or retrieved text.
  def self.field_problem_block(session, trace: nil)
    return "" unless field_problem_readable?(session)

    episode = Rag::ActiveEpisode.parse(session.active_episode)
    return "" if episode.blank?

    render_field_problem(episode, trace)
  end

  # Returns S3 URIs of all active entities (= pinned docs) that have a known source_uri.
  # Used by BedrockRagService to scope KB retrieval to pinned documents.
  FABRICATED_URI_PATTERN = %r{\As3://(unknown|unknown-bucket|placeholder|no[_-]?bucket)/}i.freeze

  def self.entity_s3_uris(session)
    return [] if session.nil?

    raw = if session.uses_document_focus?
      session.document_focus_entries.pluck("source_uri")
    else
      session.active_entities.values.filter_map { |meta| meta["source_uri"] if meta.is_a?(Hash) }
    end
    filter_focus_uris(raw)
  end

  def self.filter_focus_uris(uris)
    Array(uris).map(&:to_s)
      .select { |uri| uri.start_with?("s3://") }
      .reject { |uri| uri.match?(FABRICATED_URI_PATTERN) }
      .reject { |uri| uri.include?("PIPELINE_INJECTED") }
      .uniq
  end

  def self.focused_for_prompt?(session)
    if session.uses_document_focus?
      session.document_focus_entries.any?
    else
      session.has_active_entities?
    end
  end

  def self.focus_prompt_lines(session)
    if session.uses_document_focus?
      web_focus_prompt_lines(session)
    else
      entities_sorted_by_recency(session).map { |key, meta| legacy_focus_line(key, meta) }
    end
  end

  def self.legacy_focus_line(key, meta)
    entity_type = meta["entity_type"].presence || meta["source"]
    type = entity_type == "image_upload" ? "image" : "document"
    aliases = Array(meta["aliases"]).compact_blank.first(MAX_ALIASES_PER_ENTITY)
    summary = meta["first_answer_summary"]
    alias_note = aliases.any? ? "  (also: #{aliases.join(', ')})" : ""
    summary_note = summary.present? ? "\n    Summary: #{summary}" : ""
    "- [#{type}] #{key}#{alias_note}#{summary_note}"
  end

  def self.web_focus_prompt_lines(session)
    entries = session.document_focus_entries.sort_by { |entry|
      [ -(parse_added_at(entry["added_at"])&.to_i || 0) ]
    }
    documents = KbDocument.where(id: entries.pluck("kb_document_id")).index_by(&:id)
    entries.map do |entry|
      document = documents[entry["kb_document_id"]]
      type = ConversationSession.media_type_for(document || entry["source_uri"])
      label = type == "image_upload" ? "image" : "document"
      aliases = document ? Array(document.aliases).compact_blank.first(MAX_ALIASES_PER_ENTITY) : []
      name = entry["display_name"].presence || document&.display_name || "document"
      alias_note = aliases.any? ? "  (also: #{aliases.join(', ')})" : ""
      "- [#{label}] #{name}#{alias_note}"
    end
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

  def self.field_problem_readable?(session)
    session.channel == "web" &&
      !SharedSession::ENABLED &&
      Rag::FieldCompanionEpisodeFlag.enabled? &&
      Rag::FieldCompanionTurnFlag.enabled?
  end
  private_class_method :field_problem_readable?

  def self.active_photo_block(session, explicit)
    context = explicit
    context = session.turn_active_photo_context if context.nil? && session.respond_to?(:turn_active_photo_context)
    return "" if context.nil? || !context.respond_to?(:generation_block)

    block = context.generation_block.to_s
    return "" if block.empty?

    episode = Rag::ActiveEpisode.parse(session.active_episode)
    return "" unless context.matches?(episode.active_photo&.dig("field_photo_id"))

    block
  end
  private_class_method :active_photo_block

  def self.compose_with_photo(problem, photo, rest, trace = nil)
    head = [ problem, photo ].compact_blank.join("\n\n")
    if rest.empty?
      trace[:truncated] = true if trace && head.length > MAX_CONTEXT_CHARS
      note_omission(trace, "hard_cap", head[MAX_CONTEXT_CHARS..]) if head.length > MAX_CONTEXT_CHARS
      return head[0, MAX_CONTEXT_CHARS]
    end

    budget = MAX_CONTEXT_CHARS - head.length - 2
    if budget <= 0
      trace[:truncated] = true if trace && (rest.present? || head.length > MAX_CONTEXT_CHARS)
      note_omission(trace, "session_context", rest) if rest.present?
      note_omission(trace, "hard_cap", head[MAX_CONTEXT_CHARS..]) if head.length > MAX_CONTEXT_CHARS
      return head[0, MAX_CONTEXT_CHARS]
    end

    if rest.length > budget
      trace[:truncated] = true if trace
      trimmed = rest[0, budget]
      note_omission(trace, "session_context", rest[trimmed.to_s.length..])
    else
      trimmed = rest
    end
    trimmed.empty? ? head : "#{head}\n\n#{trimmed}"
  end
  private_class_method :compose_with_photo

  def self.compose_with_problem(problem, rest, trace = nil)
    return problem if rest.empty?

    budget = MAX_CONTEXT_CHARS - problem.length - 2
    if rest.length > budget
      trace[:truncated] = true if trace
      trimmed = rest[0, budget]
      note_omission(trace, "session_context", rest[trimmed.to_s.length..])
    else
      trimmed = rest
    end
    trimmed.empty? ? problem : "#{problem}\n\n#{trimmed}"
  end
  private_class_method :compose_with_problem

  def self.render_field_problem(episode, trace = nil)
    leading = []
    %w[manufacturer model controller fault_code].each { |key| append_user_fact(leading, episode, key) }
    identifiers = identifier_line(episode)
    leading << identifiers if identifiers
    optional = []
    photo = photo_line(episode)
    optional << photo if photo
    optional.concat(conflict_lines(episode))
    trailing = []
    corrected = correction_line(episode)
    trailing << corrected if corrected
    fit_problem(
      episode.goal&.[]("text").to_s.squish,
      leading,
      optional,
      compact_observations(episode),
      trailing,
      trace
    )
  end
  private_class_method :render_field_problem

  def self.append_user_fact(lines, episode, key)
    fact = episode.fact(key)
    return if fact.nil?

    case fact["status"]
    when "unknown_confirmed"
      line = UNKNOWN_FACT_LINE[key]
      lines << line if line
    when "absent_confirmed"
      lines << ABSENT_FAULT_LINE if key == "fault_code"
    when "known"
      source = fact["source"].to_s
      return unless %w[user catalog].include?(source)

      value = fact["value"].to_s.squish
      return if value.empty?

      marker = source == "catalog" ? "catalog" : "technician"
      lines << "#{FACT_LABEL[key]}: #{value} (#{marker})"
    end
  end
  private_class_method :append_user_fact

  def self.identifier_line(episode)
    values = episode.identifiers.filter_map do |item|
      source = item["source"].to_s
      next unless source.empty? || source == "user"

      item["value"].to_s.squish.presence
    end
    return nil if values.empty?

    "Identifiers: #{values.join(', ')}"
  end
  private_class_method :identifier_line

  def self.photo_line(episode)
    bits = %w[manufacturer model].filter_map do |key|
      fact = episode.fact(key)
      next unless fact && fact["status"] == "known" && fact["source"] == "photo"

      value = fact["value"].to_s.squish
      next if value.empty?

      "#{key} #{value}"
    end
    return nil if bits.empty?

    "Read from the photo, not stated by the technician: #{bits.join(', ')}"
  end
  private_class_method :photo_line

  def self.compact_observations(episode)
    seen = []
    episode.observations.filter_map do |item|
      text = item["text"].to_s.squish
      next if text.empty? || stale_observation?(text, episode)
      next if Rag::ObservationText.redundant?(text, seen)

      seen << Rag::ObservationText.normalize(text)
      text
    end
  end
  private_class_method :compact_observations

  def self.correction_line(episode)
    rows = episode.rejected.filter_map do |item|
      value = item["value"].to_s.squish
      next if value.empty?

      label = FACT_LABEL[item["slot"]] || item["slot"].to_s.tr("_", " ")
      "#{label.downcase} #{value}"
    end
    return nil if rows.empty?

    "Not current: #{rows.join('; ')}"
  end
  private_class_method :correction_line

  # Drop an observation only when it states the rejected value as that slot.
  # A shared number is not enough: "LED 8" is not the rejected fault code 8.
  def self.stale_observation?(text, episode)
    normalized = Rag::FollowupQueryRewriter.normalize_label(text)
    episode.rejected.any? do |item|
      rejected = item["value"].to_s
      current = episode.fact(item["slot"])&.dig("value").to_s
      attributable_rejection?(normalized, item["slot"], rejected) &&
        !attributable_rejection?(normalized, item["slot"], current)
    end
  end
  private_class_method :stale_observation?

  def self.attributable_rejection?(normalized, slot, value)
    Rag::SlotRejection.attributable?(normalized, slot, value)
  end
  private_class_method :attributable_rejection?

  def self.conflict_lines(episode)
    episode.conflicts.filter_map do |row|
      user = row["user"].to_s.squish
      photo = row["photo"].to_s.squish
      next if user.empty? && photo.empty?

      "Conflict: technician said #{user}; the photo shows #{photo}. Mention it; do not resolve it."
    end
  end
  private_class_method :conflict_lines

  # Keep the goal, the identity, the current code, and the rejected values.
  # Exact copies and continuity echoes leave first. Then the oldest remaining
  # observation. An observation covered by the goal is omitted only while that
  # goal is still printed. The header and the footer stay inside the cap.
  def self.fit_problem(goal, leading, optional, observations, trailing, trace = nil)
    goal = goal.to_s
    leading = leading.compact
    optional = optional.compact
    observations = observations.dup
    trailing = trailing.compact

    loop do
      visible = visible_observations(goal, observations)
      text = assemble_problem(goal, leading, optional, visible, trailing)
      return finish_problem_fit(text, trace) if text.length <= MAX_PROBLEM_CHARS

      trace[:truncated] = true if trace
      if (index = oldest_visible_observation(goal, observations))
        note_omission(trace, "observation", observations[index])
        observations.delete_at(index)
        next
      end
      if optional.any?
        note_omission(trace, "optional", optional.first)
        optional.shift
        next
      end
      if goal.present?
        overflow = text.length - MAX_PROBLEM_CHARS
        if overflow >= goal.length
          note_omission(trace, "goal", goal)
          goal = ""
        else
          note_omission(trace, "goal", goal[(goal.length - overflow)..])
          goal = goal[0, goal.length - overflow].rstrip
        end
        next
      end
      if trailing.any?
        note_omission(trace, "trailing", trailing.last)
        trailing.pop
        next
      end
      if leading.any?
        note_omission(trace, "leading", leading.last)
        leading.pop
        next
      end

      note_omission(trace, "hard_cap", text[MAX_PROBLEM_CHARS..])
      return finish_problem_fit(text[0, MAX_PROBLEM_CHARS], trace)
    end
  end
  private_class_method :fit_problem

  def self.finish_problem_fit(text, trace)
    return text unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "context_fit",
      "part" => "problem",
      "chars" => text.to_s.length,
      "truncated" => trace&.[](:truncated) == true,
      "omitted" => Array(trace && trace[:omitted]),
      "problem_cap" => MAX_PROBLEM_CHARS
    )
    text
  end
  private_class_method :finish_problem_fit

  def self.note_omission(trace, part, text)
    return unless trace && Rag::ValidationCapture.active?

    body = text.to_s
    return if body.empty?

    (trace[:omitted] ||= []) << { "part" => part, "text" => body }
  end
  private_class_method :note_omission

  def self.record_context_fit(text, trace)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "context_fit",
      "part" => "session_context",
      "chars" => text.to_s.length,
      "truncated" => trace[:truncated] == true,
      "omitted" => Array(trace[:omitted]),
      "problem_cap" => MAX_PROBLEM_CHARS,
      "context_cap" => MAX_CONTEXT_CHARS
    )
  end
  private_class_method :record_context_fit

  def self.visible_observations(goal, observations)
    observations.reject { |text| goal.present? && Rag::ObservationText.covered_by?(goal, text) }
  end
  private_class_method :visible_observations

  def self.oldest_visible_observation(goal, observations)
    observations.each_index.find { |index|
      text = observations[index]
      goal.blank? || !Rag::ObservationText.covered_by?(goal, text)
    }
  end
  private_class_method :oldest_visible_observation

  def self.assemble_problem(goal, leading, optional, observations, trailing)
    body = []
    body << "Goal: #{goal}" if goal.present?
    leading.each { |line| body << line }
    optional.each { |line| body << line }
    body << "Obs: #{observations.join('; ')}" if observations.any?
    trailing.each { |line| body << line }
    ([ PROBLEM_HEADER ] + body + [ PROBLEM_FOOTER ]).join("\n")
  end
  private_class_method :assemble_problem
end
