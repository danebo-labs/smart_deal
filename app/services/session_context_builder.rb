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
  ASSISTANT_HISTORY_NOTE = "User lines are technician reports. Assistant lines are earlier conclusions of this assistant, not technician reports and not confirmed facts. A later technician message can correct them."
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

  # Companion-turn context. The case and the technician turns use their own
  # budgets. A line that does not fit is omitted whole and named. The
  # previous reply is one full prompt_reply and does not pass through the
  # 200-character cut or MAX_CONTEXT_CHARS. An observation is omitted only
  # when its normalized text equals the result of a check with the same
  # correlation. The episode is not modified.
  COMPANION_CASE_BUDGET = 3_500
  COMPANION_TURN_BUDGET = 4_000
  COMPANION_NEGATION = /(?<![[:alnum:]])\b(?:no|ni|nunca)\b(?![[:alnum:]])/i
  COMPANION_CORRECTION = /\b(?:corrij\w*|correcci[oó]n)\b/i

  def self.companion_case_budget
    COMPANION_CASE_BUDGET
  end

  def self.companion_turn_budget
    COMPANION_TURN_BUDGET
  end

  def self.companion_context(session, episode: nil, current_message: nil, current_correlation_id: nil)
    parsed = companion_episode(session, episode)
    trace = { truncated: false }
    case_text = companion_case(parsed, trace, session: session)
    turns = companion_technician_turns(
      session, current_message: current_message, current_correlation_id: current_correlation_id, trace: trace
    )
    [ case_text, turns, companion_prior_answer(session) ].compact_blank.join("\n\n")
  end

  def self.companion_episode(session, episode)
    return episode if episode.is_a?(Rag::ActiveEpisode)
    return Rag::ActiveEpisode.parse(episode) if episode.present?
    return nil unless session.respond_to?(:active_episode)

    Rag::ActiveEpisode.parse(session.active_episode)
  end

  def self.companion_case(episode, trace, session: nil)
    return "" if episode.nil? || episode.blank?

    units = [ companion_unit("Caso:", keep: true) ]
    goal = episode.goal&.[]("text").to_s.squish
    units << companion_unit("Objetivo: #{goal}", keep: true) if goal.present?
    identity = companion_identity(episode)
    units << companion_unit("Identidad: #{identity}", keep: true) if identity.present?
    observations = companion_observations(episode)
    if observations.any?
      units << companion_unit("Observaciones:", keep: true)
      observations.each do |item|
        line = "- #{item['text']}"
        units << companion_unit(line, protect: companion_protected_text?(line))
      end
    end
    companion_check_lines(episode, session).each do |line|
      units << companion_unit(line, keep: !line.start_with?("- "), protect: companion_protected_text?(line))
    end
    text = fit_companion_units(units, companion_case_budget, trace, "companion_case").join("\n")
    finish_problem_fit(text, trace)
  end

  def self.companion_observations(episode)
    checks = Array(episode.checks)
    Array(episode.observations).reject do |item|
      normalized = Rag::ObservationText.normalize(item["text"])
      next false if normalized.blank?

      checks.any? do |check|
        check["correlation_id"].to_s == item["correlation_id"].to_s &&
          check["result"].present? &&
          Rag::ObservationText.normalize(check["result"]) == normalized
      end
    end
  end

  def self.companion_identity(episode)
    parts = []
    %w[manufacturer model].each do |key|
      fact = episode.fact(key)
      next unless fact.is_a?(Hash) && fact["status"] == "known"
      next unless %w[user catalog].include?(fact["source"].to_s)

      value = fact["value"].to_s.squish
      parts << value if value.present?
    end
    Array(episode.identifiers).each do |item|
      next unless item.is_a?(Hash)

      source = item["source"].to_s
      next unless source.empty? || source == "user"

      value = item["value"].to_s.squish
      next if value.blank? || check_result_identifier?(episode, item, value)

      parts << value
    end
    parts.uniq.join(", ")
  end

  # A stored check result is not an equipment identifier. The same words with
  # another correlation stay, because they were not that result.
  def self.check_result_identifier?(episode, item, value)
    label = Rag::FollowupQueryRewriter.normalize_label(value)
    return false if label.blank?

    correlation = item["correlation_id"].to_s
    Array(episode.checks).any? { |check|
      check["correlation_id"].to_s == correlation &&
        Rag::FollowupQueryRewriter.normalize_label(check["result"]) == label
    }
  end

  def self.companion_check_lines(episode, session)
    checks = Array(episode.checks).select { |item| item.is_a?(Hash) && item["subject"].present? }
    done, pending = checks.partition { |item| item["status"].to_s == "done" }
    lines = []
    if done.any?
      lines << "Comprobaciones realizadas:"
      done.each { |item| lines << companion_done_line(item, session) }
    end
    if pending.any?
      lines << "Reportes del técnico sobre comprobaciones no realizadas. No son una agenda ni una tarea prescrita:"
      pending.each { |item| lines << companion_pending_line(item, session) }
    end
    lines
  end

  def self.companion_done_line(item, session)
    span = companion_report_span(session, item)
    result = item["result"].to_s.squish
    line = "- hecha."
    line = "#{line} resultado: «#{result}»." if result.present?
    line + companion_span_clause(span, item["subject"], done: true)
  end

  def self.companion_pending_line(item, session)
    span = companion_report_span(session, item)
    "- reporte del técnico, no es una tarea prescrita." + companion_span_clause(span, item["subject"], done: false)
  end

  def self.companion_span_clause(span, subject, done:)
    case span[:kind]
    when :original
      " texto original del mensaje: «#{span[:text]}».#{companion_provenance_clause(span)}"
    when :truncated_store
      " texto almacenado truncado, no es el mensaje íntegro: «#{span[:text]}».#{companion_provenance_clause(span)}"
    else
      derived = " representación derivada del estado, no es una cita literal del técnico. sujeto: #{subject.to_s.squish}."
      derived += " el caso no la marca como hecha." unless done
      derived + companion_provenance_clause(span)
    end
  end

  def self.companion_provenance_clause(span)
    bits = []
    bits << "correlación #{span[:correlation_id]}" if span[:correlation_id].present?
    bits << "procedencia del texto: #{span[:provenance]}" if span[:provenance].present?
    return "" if bits.empty?

    " #{bits.join('. ')}."
  end

  def self.companion_report_span(session, item)
    message = companion_message_for(session, item["correlation_id"])
    base = {
      correlation_id: item["correlation_id"].to_s.presence,
      provenance: message.is_a?(Hash) ? message["text_provenance"].to_s.presence : nil
    }
    return base.merge(kind: :derived) unless message.is_a?(Hash)

    content = companion_message_text(message)
    if companion_message_cut?(message)
      return base.merge(kind: :truncated_store, text: content)
    end

    needles = [ item["result"], item["subject"] ].map { |value| value.to_s.squish }.reject(&:empty?)
    sentences = content.split(/(?<=[.!?])\s+/).map(&:strip).reject(&:empty?)
    hits = sentences.select { |sentence| needles.any? { |needle| companion_sentence_has?(sentence, needle) } }
    return base.merge(kind: :original, text: hits.first) if hits.one?

    base.merge(kind: :derived)
  end

  def self.companion_sentence_has?(sentence, needle)
    return false if needle.blank?
    return true if sentence.include?(needle)

    Rag::ObservationText.covered_by?(sentence, needle)
  end

  def self.companion_message_for(session, correlation_id)
    return nil if correlation_id.blank?
    return nil unless session.respond_to?(:conversation_history)

    Array(session.conversation_history).find do |message|
      message.is_a?(Hash) && message["role"] == "user" && message["correlation_id"].to_s == correlation_id.to_s
    end
  end

  def self.companion_stored_truncated?(content)
    text = content.to_s
    text.length == ConversationSession::MAX_MSG_LENGTH && text.end_with?("...")
  end

  def self.companion_protected_text?(text)
    body = text.to_s
    body.match?(COMPANION_NEGATION) || body.match?(COMPANION_CORRECTION)
  end

  def self.companion_unit(text, keep: false, protect: false)
    { text: text, keep: keep, protect: protect }
  end

  def self.fit_companion_units(units, budget, trace, part)
    chosen = units.select { |unit| unit[:keep] }
    units.reject { |unit| unit[:keep] }.each do |unit|
      if companion_units_length(chosen + [ unit ]) <= budget
        chosen << unit
        next
      end
      replaced = false
      if unit[:protect]
        chosen.reverse_each do |existing|
          next if existing[:keep] || existing[:protect]
          next if existing.equal?(unit)

          trial = chosen.reject { |item| item.equal?(existing) } + [ unit ]
          next if companion_units_length(trial) > budget

          note_omission(trace, part, existing[:text])
          trace[:truncated] = true if trace
          chosen.delete(existing)
          chosen << unit
          replaced = true
          break
        end
      end
      next if replaced

      note_omission(trace, part, unit[:text])
      trace[:truncated] = true if trace
    end
    units.filter_map { |unit| unit[:text] if chosen.any? { |item| item.equal?(unit) } }
  end

  def self.companion_units_length(units)
    units.pluck(:text).join("\n").length
  end

  # Episode user messages in stored order, without the global cap of three.
  # The current turn is left out by its correlation id; two turns with the
  # same words are two turns. Without that id the current text is matched.
  # A stored cut stays labeled as truncated. A message that does not fit is
  # omitted whole.
  def self.companion_technician_turns(session, current_message: nil, current_correlation_id: nil, trace: nil)
    messages = companion_episode_user_messages(session)
    current = current_message.to_s.strip
    if current_correlation_id.present?
      messages = messages.reject { |message| message["correlation_id"].to_s == current_correlation_id.to_s }
    elsif current.present?
      messages = messages.reject { |message| companion_message_text(message).strip == current }
    end
    return "" if messages.empty?

    header = "Turnos del técnico, en orden. El mensaje de este turno no se repite."
    units = messages.map { |message|
      line = companion_turn_line(message)
      companion_unit(line, protect: companion_protected_text?(companion_message_text(message))).merge(message: message)
    }
    room = companion_turn_budget - header.length - 1
    kept = fit_companion_units(units, room, trace, "companion_turn")
    omitted = units.reject { |unit| kept.include?(unit[:text]) }
    record_companion_turns(messages, kept, omitted)
    lines = [ header, *kept ]
    omitted.each { |unit| lines << companion_omission_line(unit[:message]) }
    lines.join("\n")
  end

  def self.companion_message_text(message)
    message["full_content"].presence || message["content"].to_s
  end

  def self.companion_message_cut?(message)
    return message["full_content_truncated"] == true if message["full_content"].present?

    companion_stored_truncated?(message["content"])
  end

  def self.companion_turn_line(message)
    content = companion_message_text(message)
    notes = []
    notes << "texto almacenado truncado, no es el mensaje íntegro" if companion_message_cut?(message)
    notes << "procedencia: #{message['text_provenance']}" if message["text_provenance"].present?
    notes << "correlación: #{message['correlation_id']}" if message["correlation_id"].present?
    prefix = notes.empty? ? "" : "[#{notes.join('. ')}] "
    "- #{prefix}#{content}"
  end

  def self.companion_omission_line(message)
    label = message["correlation_id"].presence || "sin correlación"
    "Omitido por presupuesto, sin recortar: correlación #{label}, #{companion_message_text(message).length} caracteres."
  end

  def self.companion_episode_user_messages(session, now: Time.current)
    return [] unless session.respond_to?(:conversation_history) && session.respond_to?(:episode_history_cutoff)

    cutoff = session.episode_history_cutoff(now)
    Array(session.conversation_history).select do |message|
      next false unless message.is_a?(Hash) && message["role"] == "user"

      ts = companion_message_ts(message["ts"])
      ts && ts >= cutoff && ts <= now
    end
  end

  def self.companion_message_ts(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end

  def self.record_companion_turns(messages, kept, omitted)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "companion_turns",
      "budget" => companion_turn_budget,
      "kept" => kept.size,
      "seen" => messages.size,
      "omitted" => omitted.pluck(:text)
    )
  end

  def self.companion_prior_answer(session)
    message = companion_prior_message(session)
    return "" if message.nil?

    mark = message["prompt_reply_truncated"] == true ? "«antecedente truncado»\n" : ""
    "Conclusión previa de Danebo. No es un hecho confirmado.\n#{mark}#{message['prompt_reply']}"
  end

  def self.companion_prior_message(session)
    return nil unless session.respond_to?(:conversation_history) && session.respond_to?(:episode_history_cutoff)

    cutoff = session.episode_history_cutoff
    now = Time.current
    chosen = nil
    Array(session.conversation_history).each do |message|
      next unless message.is_a?(Hash) && message["role"] == "assistant"

      ts = begin
        Time.zone.parse(message["ts"].to_s)
      rescue StandardError
        nil
      end
      next if ts.nil? || ts < cutoff || ts > now

      chosen = message
    end
    return nil unless chosen&.key?("prompt_reply")
    return nil if chosen["prompt_reply"].to_s.blank?

    chosen
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

    # Episode window in stored order. The current question stays where it
    # was recorded. Only the latest assistant turn is included, truncated
    # to 200 characters.
    history =
      if Rag::EpisodeScopeFlag.enabled? && session.respond_to?(:episode_prompt_history)
        session.episode_prompt_history.map do |turn|
          content = turn[:content].to_s
          content = content.truncate(200) if turn[:role] == "assistant"
          { role: turn[:role], content: content }
        end
      else
        session.recent_history_for_prompt(turns: 3)
      end
    if history.any?
      history_lines = history.map { |h| "#{h[:role].capitalize}: #{h[:content]}" }.join("\n")
      assistant_note = history.any? { |turn| turn[:role].to_s == "assistant" } ? "#{ASSISTANT_HISTORY_NOTE}\n" : ""
      parts << <<~BLOCK.strip
        ## Recent Conversation
        #{assistant_note}#{history_lines}
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

  # Observations the case record may quote. Same compaction as the prompt
  # block, including the omission of an observation the goal already states.
  def self.case_observations(episode)
    return [] unless episode.respond_to?(:observations)

    goal = episode.goal&.[]("text").to_s.squish
    visible_observations(goal, compact_observations(episode))
  end

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
    leading.concat(check_lines(episode))
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

  def self.check_lines(episode)
    return [] unless episode.respond_to?(:checks)

    Array(episode.checks).filter_map { |item|
      subject = item["subject"].to_s.squish
      next if subject.empty?

      status = item["status"].to_s
      result = item["result"].to_s.squish
      line = "Check: #{subject} (#{status})"
      result.present? ? "#{line}: #{result}" : line
    }
  end
  private_class_method :check_lines

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
