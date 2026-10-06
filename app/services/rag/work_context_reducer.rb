# frozen_string_literal: true

module Rag
  # The only linguistic writer of the episode in owner mode. It does not write
  # Document Focus.
  class WorkContextReducer
    def self.apply!(episode:, perception:, decision:, turn:, correlation_id:, now:)
      new(
        episode: episode, perception: perception, decision: decision,
        turn: turn, correlation_id: correlation_id, now: now
      ).apply!
    end

    def initialize(episode:, perception:, decision:, turn:, correlation_id:, now:)
      @episode = episode
      @perception = perception
      @decision = decision
      @turn = turn.to_s
      @correlation_id = correlation_id
      @now = now
    end

    def apply!
      return @episode if @perception.nil?
      return @episode if @decision&.decision == "meta"

      promote_carry if promote_existing_carry?

      if @decision&.decision == "clarify_first"
        @episode.touch!(@now)
        return @episode if @perception.move == "new_work"

        write_pending(@decision.pending_question)
        return @episode
      end
      return @episode if @perception.move == "unclear"

      apply_negations
      write_assertions
      write_replacement_fault_code
      write_absent_fault_code
      write_observations unless @decision&.decision == "clarify_first"
      assign_goal_if_needed
      clear_pending_unless_meta
      @episode.touch!(@now)
      @episode
    end

    private

    def answer_promotes_carry?
      @perception.move == "answer_pending" && %w[value unknown seek].include?(@perception.pending_resolution)
    end

    def promote_existing_carry?
      return true if answer_promotes_carry?
      return false unless %w[follow_up correct].include?(@perception.move)

      conversational_pending?
    end

    def conversational_pending?
      PendingQuestion::CONVERSATIONAL_TYPES.include?(@episode.pending_question&.dig("type"))
    end

    def promote_carry
      Array(@episode.pending_question&.dig("carry")).each do |span|
        @episode.append_identifier!(span, correlation_id: @correlation_id, source: "user")
      end
    end

    def apply_negations
      @perception.identities.select { |item| item.kind == "negate" && item.slot.present? }.each do |item|
        if item.slot == "identifier"
          remove_identifier(item.span)
          @episode.append_rejected!("identifier", item.span)
        elsif ActiveEpisode::FACT_KEYS.include?(item.slot)
          fact = @episode.fact(item.slot)
          value = fact&.dig("value").presence || item.span
          if item.slot == "controller" && @episode.fact("manufacturer")&.dig("source") == "catalog"
            strip_value(@episode.fact("manufacturer")["value"])
            @episode.clear_fact!("manufacturer")
          end
          @episode.clear_fact!(item.slot)
          @episode.append_rejected!(item.slot, value)
          strip_value(value)
        end
      end
    end

    def write_assertions
      @perception.facts.each do |item|
        @episode.delete_rejected!(item.slot, item.value)
        @episode.write_fact!(
          item.slot,
          status: "known",
          value: item.value,
          source: item.source.presence || "user",
          correlation_id: @correlation_id,
          at: @now.iso8601
        )
        next if item.manufacturer.blank? || item.slot == "manufacturer"

        @episode.delete_rejected!("manufacturer", item.manufacturer)
        @episode.write_fact!(
          "manufacturer",
          status: "known",
          value: item.manufacturer,
          source: "catalog",
          correlation_id: @correlation_id,
          at: @now.iso8601
        )
      end
      if @perception.move == "answer_pending" && @perception.pending_resolution == "unknown"
        slot = pending_slot
        if %w[manufacturer model controller].include?(slot)
          @episode.write_fact!(slot, status: "unknown_confirmed", source: "user", correlation_id: @correlation_id, at: @now.iso8601)
        end
      elsif @perception.move == "answer_pending" && @perception.pending_resolution == "absent"
        @episode.write_fact!("fault_code", status: "absent_confirmed", source: "user", correlation_id: @correlation_id, at: @now.iso8601)
      end
      @perception.identifiers.each do |item|
        @episode.delete_rejected!("identifier", item.value)
        @episode.append_identifier!(item.value, correlation_id: @correlation_id, source: "user")
      end
    end

    def write_observations
      return if %w[meta clarify_first].include?(@decision&.decision)

      @perception.observations.each do |text|
        @episode.append_observation!(text, correlation_id: @correlation_id)
      end
      supersede_retracted_observations
    end

    # A correction names the replacement as a mention when the turn has no
    # manufacturer, model, or controller fact. The reducer adopts that mention
    # onto the negated fault-code slot. It does not invent a code meaning.
    def write_replacement_fault_code
      return unless @perception.move == "correct"
      return if @episode.fact("fault_code")&.dig("status") == "known"

      negated = @perception.identities.select { |item| item.kind == "negate" && item.slot == "fault_code" }
      return if negated.empty?

      negated_labels = negated.map { |item| FollowupQueryRewriter.normalize_label(item.value.presence || item.span) }
      mention = @perception.mentions.find { |item|
        label = FollowupQueryRewriter.normalize_label(item.value.presence || item.span)
        label.match?(TurnPerception::FAULT_RE) && negated_labels.exclude?(label)
      }
      return if mention.nil?

      value = (mention.value.presence || mention.span).to_s
      @episode.delete_rejected!("fault_code", value)
      @episode.write_fact!(
        "fault_code",
        status: "known",
        value: value,
        source: "user",
        correlation_id: @correlation_id,
        at: @now.iso8601
      )
    end

    # "No aparece código de falla" is a report, not an answer to a pending slot.
    # Reuse the fallback absence phrase. Do not replace a known code.
    def write_absent_fault_code
      return if @perception.identities.any? { |item| item.kind == "negate" && item.slot.blank? }

      current = @episode.fact("fault_code")
      return if current && %w[known absent_confirmed].include?(current["status"])

      text = ([ @turn ] + Array(@perception.observations)).join(" ")
      return unless FollowupQueryRewriter.normalize_label(text).match?(ActiveEpisodeTurn::ABSENT_CODE_RE)

      @episode.write_fact!(
        "fault_code",
        status: "absent_confirmed",
        source: "user",
        correlation_id: @correlation_id,
        at: @now.iso8601
      )
    end

    def supersede_retracted_observations
      retracted_phrases.each { |phrase| drop_observations_matching(phrase) }
      return unless @turn.match?(/\bcorrijo\b/i)

      fresh = Array(@perception.observations).map { |text| text.to_s.squish }
      @episode.observations.reject! { |item|
        text = item["text"].to_s
        next false if fresh.any? { |phrase| same_label?(phrase, text) }

        fresh.any? { |phrase| observation_replaced?(text, phrase) }
      }
    end

    def retracted_phrases
      FollowupQueryRewriter.normalize_label(@turn).scan(/\bno de\s+([a-z0-9]+(?:\s+[a-z0-9]+){0,2})/).flatten
    end

    def drop_observations_matching(phrase)
      pattern = token_pattern(phrase)
      @episode.observations.reject! { |item| FollowupQueryRewriter.normalize_label(item["text"]).match?(pattern) }
    end

    def same_label?(left, right)
      FollowupQueryRewriter.normalize_label(left) == FollowupQueryRewriter.normalize_label(right)
    end

    def observation_replaced?(old_text, new_text)
      old_words = FollowupQueryRewriter.normalize_label(old_text).split
      new_words = FollowupQueryRewriter.normalize_label(new_text).split
      return false if old_words.empty?

      shared = old_words & new_words
      return false unless shared.any? { |word| word.length >= 4 }
      return false if shared.size < 4

      shared.size * 2 >= old_words.size
    end

    def assign_goal_if_needed
      return if @episode.goal.present?
      return unless @decision&.performs_retrieval?
      return unless %w[report follow_up new_work].include?(@perception.move)

      @episode.assign_goal!(durable_goal_text, correlation_id: @correlation_id)
    end

    # A validated symptom from this turn is the durable problem. The raw turn
    # stays the fallback when the interpreter returned no symptom.
    def durable_goal_text
      phrases = goal_observations
      return @turn if phrases.empty?

      phrases.join(" ")
    end

    def goal_observations
      seen = {}
      phrases = Array(@perception.observations).filter_map { |text|
        phrase = text.to_s.squish
        next if phrase.blank?

        label = FollowupQueryRewriter.normalize_label(phrase)
        next if label.blank? || seen[label]

        seen[label] = true
        phrase
      }

      kept = []
      phrases.each do |phrase|
        candidate = (kept + [ phrase ]).join(" ")
        break if kept.any? && candidate.length > ActiveEpisode::MAX_GOAL_CHARS

        kept << phrase
      end
      kept
    end

    def clear_pending_unless_meta
      return if @decision&.decision == "meta"

      @episode.clear_pending! if @perception.move != "meta"
    end

    def write_pending(question)
      @episode.clear_pending!
      coerced = PendingQuestion.coerce(question)
      return if coerced.nil?

      @episode.pending_question = coerced
      return unless PendingQuestion::FACT_TYPES.include?(coerced["type"])

      @episode.pending_fact = { "subject" => coerced["type"], "correlation_id" => @correlation_id.to_s }
    end

    def pending_slot
      type = @episode.pending_question&.dig("type")
      return type if type.present?

      @episode.pending_fact&.dig("subject")
    end

    def remove_identifier(value)
      label = FollowupQueryRewriter.normalize_label(value)
      @episode.identifiers.reject! { |item| FollowupQueryRewriter.normalize_label(item["value"]) == label }
    end

    def strip_value(value)
      return if value.blank?

      pattern = token_pattern(value)
      if @episode.goal.is_a?(Hash)
        text = @episode.goal["text"].to_s.gsub(pattern, " ").squish
        if text.blank?
          @episode.clear_goal!
        else
          @episode.goal["text"] = text
        end
      end
      @episode.observations.reject! { |item| item["text"].to_s.match?(pattern) }
    end

    def token_pattern(value)
      /(?<![[:alnum:]])#{Regexp.escape(value.to_s)}(?![[:alnum:]])/i
    end
  end
end
