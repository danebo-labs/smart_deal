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

    def coerce(raw)
      return nil unless raw.is_a?(Hash)

      type = raw["type"].to_s
      return nil unless TYPES.include?(type)
      return documented_context(raw) if type == "documented_context"

      question = { "type" => type }
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

    def documented_context(raw)
      text = raw["question"].to_s.squish.first(240)
      return nil if text.blank?

      targets = Array(raw["targets"]).filter_map { |item| documented_target(item) }
      return nil unless (1..2).cover?(targets.size)

      question = { "type" => "documented_context", "question" => text, "targets" => targets }
      about = raw["about"].to_s.squish.first(ActiveEpisode::MAX_OBSERVATION_CHARS)
      question["about"] = about if about.present?
      question["aspect"] = "scope" if raw["aspect"].to_s == "scope" && about.present?
      shown = shown_question(raw["shown"])
      question["shown"] = shown if shown
      question
    end

    # What this turn may store. A question counts when this text contains it,
    # or when it is the open question already stored. A clarification counts
    # as shown only when this text contains it, or when that same clarification
    # was already stored. A proposal that the final answer removed does not.
    def presented(pending, text, retained: nil)
      question = coerce(pending)
      return nil if question.nil? || question["question"].blank?

      body = text.to_s
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
      return nil if question["aspect"] == "scope"

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
    private_class_method :referent_move?, :unknown_referent?, :declared_referent_spans
  end
end
