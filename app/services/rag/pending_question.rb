# frozen_string_literal: true

module Rag
  # Machine-readable question Ruby already knows it asked. No model call.
  module PendingQuestion
    TYPES = %w[fault_code manufacturer model controller choice absent work_relation referent correction_target documented_context].freeze
    CONVERSATIONAL_TYPES = %w[work_relation referent correction_target].freeze
    MAX_CARRY = 2
    FACT_TYPES = %w[fault_code manufacturer model controller].freeze
    CHOICE_OPENING = %w[opening closing].freeze
    DOCUMENTED_REPLIES = {
      "si" => "yes",
      "no" => "no",
      "no se" => "unknown",
      "no lo se" => "unknown",
      "no puedo verlo" => "unknown"
    }.freeze
    # A longer "no sé cómo / si" answers the open question. "No se enciende"
    # does not: that is a state, not a limit.
    UNKNOWN_CLARIFICATION = /\Ano (?:lo )?se(?:\s+como|\s+distingu|\s+ver|\s+si)\b/

    module_function

    # coerce_stored lets a documented check that cites no source keep an empty
    # targets list. Only the readers of a stored or published pending use it
    # (ActiveEpisode.parse, the assistant write, presented). A question built
    # from a clarification still needs its targets (coerce).
    def coerce(raw)
      coerce_with(raw, untargeted: false)
    end

    # Reader of a pending that Ruby already stored or published.
    def coerce_stored(raw)
      coerce_with(raw, untargeted: true)
    end

    def coerce_with(raw, untargeted:)
      return nil unless raw.is_a?(Hash)

      type = raw["type"].to_s
      return nil unless TYPES.include?(type)
      return documented_context(raw, untargeted: untargeted) if type == "documented_context"

      question = { "type" => type }
      text = raw["question"].to_s.squish.first(240)
      question["question"] = text if type == "controller" && text.present?
      carry = sanitize_carry(raw["carry"])
      question["carry"] = carry if carry.any?
      return question unless type == "choice"

      options = Array(raw["options"]).map { |option| option.to_s.strip }.reject(&:empty?)
      return nil if options.empty?

      question["options"] = options
      question
    end

    # Closed replies only. A structured question wins over pending_fact.
    def parse_reply(text, pending_question: nil, pending_fact: nil)
      question = coerce(pending_question)
      type = question ? question["type"] : pending_fact&.dig("subject").to_s
      raw = text.to_s.strip
      if type == "fault_code" && raw.casecmp?("ninguno")
        return { "type" => "fault_code", "status" => "absent" }
      end
      if question && question["type"] == "choice" && question["options"] == CHOICE_OPENING && raw.casecmp?("al abrir")
        return { "type" => "choice", "value" => "opening" }
      end
      documented = documented_reply(question, raw)
      return documented if documented

      nil
    end

    def documented_context(raw, untargeted: false)
      text = raw["question"].to_s.squish.first(240)
      return nil if text.blank?

      targets = Array(raw["targets"]).filter_map { |item| documented_target(item) }
      # A published check that cites no source has no documented target. Ruby
      # does not invent one (from_publication). More than two is not a target list.
      return nil if targets.size > 2
      return nil if targets.empty? && !(untargeted && raw["targets"].is_a?(Array))

      question = { "type" => "documented_context", "question" => text, "targets" => targets }
      id = raw["id"].to_s
      question["id"] = id if id.match?(/\Aq\d+\z/)
      parts = contract_parts(raw["parts"])
      question["parts"] = parts if parts.any?
      about = raw["about"].to_s.squish.first(ActiveEpisode::MAX_OBSERVATION_CHARS)
      question["about"] = about if about.present?
      question["aspect"] = "scope" if raw["aspect"].to_s == "scope" && about.present?
      if raw["aspect"] == "parameter_reading" && targets.one? && CompanionParameterReview.parameter?(about)
        question["aspect"] = "parameter_reading"
      end
      shown = shown_question(raw["shown"])
      question["shown"] = shown if shown
      question
    end

    # The technical question the published answer actually asks. A trailing
    # manual notice, an insufficient-evidence line, or the controller plate
    # question is not that question. A plate question that is the only
    # question stays with the structured pending that published it.
    def followup_line(text, locale: I18n.locale)
      lines = text.to_s.rstrip.lines.map(&:strip).reject(&:empty?)
      skipped = trailing_notice_lines(locale)
      lines.pop while lines.last && skipped.include?(lines.last.squish)
      line = lines.reverse.find { |candidate| candidate.match?(/[?？]\z/) }
      return nil unless line

      question = line[/¿[^¿?]{1,158}\?\z/]
      question ||= line[/\A[^¿?]{1,159}\?\z/] if locale.to_s.start_with?("en")
      question
    end

    # Fixed labels the publisher puts in front of the check. They are not
    # part of the question the technician answers.
    LABEL_WORDS = "(?:(?:pr[oó]xima|siguiente|next)\\s+)?(?:comprobaci[oó]n|pregunta|verificaci[oó]n|check|question|pergunta)"
    PUBLICATION_LABEL = /\A(?:\*\*#{LABEL_WORDS}:\*\*|\*\*#{LABEL_WORDS}\*\*:|#{LABEL_WORDS}:)\s*/i
    # A citation or a closing quote right before "¿" also ends the sentence.
    SENTENCE_BREAK = /(?<=[.!?？])\s+(?=[¿¡A-ZÁÉÍÓÚÑ"«(\[*])|(?<=[\]»])\s+(?=¿)/
    QUESTION_END = /[?？]\z/
    MAX_QUESTION_CHARS = 240

    # The one writer of the pending documented question. The text is the last
    # interrogative line of the published answer, with the condition that
    # opens its sentence and without the publisher's label. Targets are the
    # sources cited with [n] in that line's paragraph. No citation, no target:
    # Ruby does not turn the question itself into a documented item.
    # sources is the numbered list the answer was generated from.
    def from_publication(text, sources: [], locale: I18n.locale)
      body = text.to_s.rstrip
      line = last_question_line(body, locale)
      return nil unless line

      question = publication_question(line)
      return nil if question.blank?

      blocks = body.split(/\n{2,}/)
      position = blocks.index { |block| block.include?(line) }
      paragraph = position ? blocks[position].to_s : ""
      targets = cited_targets(paragraph, sources)
      targets = cited_targets(labeled_check_block(blocks, position), sources) if targets.empty? && paragraph.scan(/\[\d+\]/).empty?
      coerce_stored("type" => "documented_context", "question" => question, "targets" => targets)
    end

    CHECK_LABEL_BLOCK = /\A(?:\*\*)?#{LABEL_WORDS}(?:\s*\([^)\n]{1,40}\))?(?:\*\*)?:/i

    # Stage 1, flag on. The writer sometimes puts the manual's line in the
    # check's own labelled paragraph and the question alone below it. That
    # paragraph, and only that one, backs the question.
    def labeled_check_block(blocks, position)
      return "" unless Rag::CheckOutcomeFlag.enabled? && position&.positive?

      previous = blocks[position - 1].to_s.strip
      previous.match?(CHECK_LABEL_BLOCK) ? previous : ""
    end

    # The question of a published text, as from_publication would store it.
    # The history keeps that text, so a closed check can be named again.
    def question_in(text, locale: I18n.locale)
      line = last_question_line(text.to_s.rstrip, locale)
      line && publication_question(line)
    end

    def last_question_line(body, locale)
      lines = body.lines.map(&:strip).reject(&:empty?)
      skipped = trailing_notice_lines(locale)
      lines.pop while lines.last && skipped.include?(lines.last.squish)
      lines.reverse_each do |candidate|
        return candidate if candidate.match?(QUESTION_END)

        trimmed = without_citation_tail(candidate)
        return trimmed if trimmed
      end
      nil
    end

    # "¿…? Según [21], DFC «…»." The sentences after the question only back it
    # with a citation. The question is still the last thing asked.
    def without_citation_tail(line)
      sentences = line.split(SENTENCE_BREAK)
      dropped = 0
      while sentences.size > 1 && !sentences.last.match?(QUESTION_END) && (sentences.last.match?(/\[\d+\]/) || explanation_tail?)
        sentences.pop
        dropped += 1
      end
      sentences.join(" ") if dropped.positive? && sentences.last.match?(QUESTION_END)
    end

    # Stage 1, flag on. The reason a question is asked («La respuesta cambia
    # si…», «Esa lectura decide…») may share its line. It does not stop the
    # question from being the last thing asked.
    def explanation_tail?
      Rag::CheckOutcomeFlag.enabled?
    end

    def publication_question(line)
      sentences = line.sub(/\A(?:[-•]|\*(?=\s))\s+/, "").split(SENTENCE_BREAK)
      tail = []
      sentences.reverse_each do |sentence|
        break unless sentence.match?(QUESTION_END)

        tail.unshift(sentence)
      end
      return nil if tail.empty?

      full = tail.map(&:strip).join(" ")
      [ full, tail.last.strip ].each do |candidate|
        text = candidate.sub(PUBLICATION_LABEL, "").strip
        return text if text.present? && text.length <= MAX_QUESTION_CHARS
      end
      nil
    end

    def cited_targets(paragraph, sources)
      list = Array(sources)
      numbers = paragraph.scan(/\[(\d+)\]/).flatten.map(&:to_i).uniq
      numbered = list.any? { |entry| entry.is_a?(Hash) && entry.key?("number") }
      numbers.filter_map { |number|
        next unless number.positive?

        # A reopened case numbers a passage by its case number, which need not
        # be its position. Sources that carry that number are read by it.
        source = numbered ? list.find { |entry| entry.is_a?(Hash) && entry["number"] == number } : list[number - 1]
        next unless source.is_a?(Hash)
        next if source["reference_only"] == true || source["applicability"].to_s == "reference_only"

        item = source["document"].to_s.squish.presence
        next if item.blank?

        { "item" => item.first(160), "document_key" => source["document_key"].to_s,
          "filename" => source["filename"].to_s, "page" => source["page"].to_s }
      }.first(2)
    end

    def trailing_notice_lines(locale)
      %w[
        controller_reference_boundary focus_evidence_insufficient
        open_evidence_insufficient controller_label_question
      ].filter_map { |key| I18n.t("rag.#{key}", locale: locale, default: nil).presence }
        .map(&:squish)
    end

    # What this turn may store. A question counts when this text contains it,
    # or when it is the open question already stored. A clarification counts
    # as shown only when this text contains it, or when that same clarification
    # was already stored. A proposal that the final answer removed does not.
    def presented(pending, text, retained: nil)
      question = coerce_stored(pending)
      return nil if question.nil? || question["question"].blank?

      body = text.to_s
      # The publisher removes a bold colon label before the technician sees it.
      # The question stored is that published wording.
      unless body.include?(question["question"])
        visible = question["question"].sub(/\A\*\*([^*\n]{1,80}?)(?::\*\*|\*\*:)/, '\1:')
        question = question.merge("question" => visible) if visible != question["question"] && body.include?(visible)
      end
      stored = retained.is_a?(Hash) ? retained : {}
      shown = question["shown"]
      if shown && body.exclude?(shown["question"]) && shown["question"] != stored.dig("shown", "question")
        question = question.except("shown")
        shown = nil
      end
      return question if body.include?(question["question"])
      return question if shown && body.include?(shown["question"]) && question["question"] == stored["question"]

      nil
    end

    # The question presented now, when it is not the unresolved datum.
    # Targets may be empty: the clarification still has to be remembered.
    def shown_question(raw)
      return nil unless raw.is_a?(Hash)

      text = raw["question"].to_s.squish.first(240)
      return nil if text.blank?

      targets = Array(raw["targets"]).filter_map { |item| documented_target(item) }.first(2)
      { "question" => text, "targets" => targets }
    end

    def contract_parts(raw)
      return [] unless raw.is_a?(Array)

      kept = []
      raw.each do |part|
        next unless part.is_a?(Hash)

        id = part["id"].to_s
        role = part["role"].to_s
        next unless id.match?(/\Ap\d+\z/) && AnswerContract::ROLES.include?(role)

        if role == "declared"
          text = part["text"].to_s
          next if text.blank? || kept.count { |item| item["role"] == "declared" } >= AnswerContract::DECLARED_LIMIT

          kept << { "id" => id, "role" => role, "text" => text }
          next
        end

        text = part["text"].to_s.squish.first(240)
        next if text.blank? || kept.any? { |item| item["role"] == role }

        kept << { "id" => id, "role" => role, "text" => text }
      end
      kept
    end

    def documented_target(raw)
      item = raw.is_a?(Hash) ? raw : { "item" => raw }
      return nil unless item.is_a?(Hash)

      text = item["item"].to_s.squish.first(160)
      return nil if text.blank?

      {
        "item" => text,
        "document_key" => item["document_key"].to_s.first(240),
        "filename" => item["filename"].to_s.first(180),
        "page" => item["page"].to_s.first(12)
      }
    end

    def documented_reply(question, raw)
      return nil unless question && question["type"] == "documented_context"
      # "¿Qué revisaste?" is not a yes/no choice. "Sí" does not confirm the section.
      return nil if %w[scope parameter_reading].include?(question["aspect"])

      label = FollowupQueryRewriter.normalize_label(raw)
      code = DOCUMENTED_REPLIES[label]
      code = "unknown" if code.nil? && label.match?(UNKNOWN_CLARIFICATION)
      return nil if code.nil?
      return nil if %w[yes no].include?(code) && Array(question["targets"]).size != 1

      { "type" => "documented_context", "r" => code }
    end

    def sanitize_carry(raw)
      return [] unless raw.is_a?(Array)

      raw.filter_map { |item|
        text = item.to_s.strip
        next if text.blank? || text.length > ActiveEpisode::MAX_VALUE_CHARS

        text
      }.uniq.first(MAX_CARRY)
    end

    # One declared assert answers an open referent. Unknown, absent, and two
    # asserts leave the question open. The span is the technician's words.
    def referent_choice(perception, turn)
      return nil if perception.nil? || unknown_referent?(perception, turn)
      return nil unless referent_move?(perception)

      spans = declared_referent_spans(perception)
      return nil unless spans.one?

      spans.first
    end

    def referent_move?(perception)
      return true if %w[follow_up report].include?(perception.move)

      perception.move == "answer_pending" && perception.pending_resolution == "value"
    end

    def unknown_referent?(perception, turn)
      return true if %w[unknown absent].include?(perception.pending_resolution.to_s)

      ActiveEpisodeTurn::UNKNOWN_RE.match?(FollowupQueryRewriter.normalize_label(turn.to_s))
    end

    def declared_referent_spans(perception)
      perception.identities.filter_map { |item|
        next unless item.act == "assert" && %w[identifier fact].include?(item.kind)

        item.span.to_s.squish.presence
      }.uniq
    end
    private_class_method :referent_move?, :unknown_referent?, :declared_referent_spans,
      :last_question_line, :publication_question, :cited_targets
  end
end
