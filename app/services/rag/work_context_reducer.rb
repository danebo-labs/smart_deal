# frozen_string_literal: true

module Rag
  # The only linguistic writer of the episode in owner mode. It does not write
  # Document Focus.
  class WorkContextReducer
    # A failed interpretation did not classify the turn. Keep the literal
    # report so the next turn still has this job. Do not write manufacturer,
    # model, controller, or any other extracted identity.
    def self.retain_uninterpreted_report!(episode:, turn:, correlation_id:, now:)
      return episode unless RoutePolicy.searchable_symptom?(turn)

      working = episode.presence || ActiveEpisode.open(correlation_id: correlation_id, now: now)
      working.touch!(now)
      literal = turn.to_s.squish
      working.assign_goal!(literal, correlation_id: correlation_id) if working.goal.blank?
      working.append_observation!(literal, correlation_id: correlation_id)
      working
    end

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
            strip_value(@episode.fact("manufacturer")["value"], slot: "manufacturer")
            @episode.clear_fact!("manufacturer")
          end
          @episode.clear_fact!(item.slot)
          @episode.append_rejected!(item.slot, value)
          remove_identifier(value)
          remove_identifier("código #{value}") if item.slot == "fault_code"
          strip_value(value, slot: item.slot)
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
        next if controller_brand_replaces_equipment?(item)

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
        next unless durable_identifier?(item.value)

        @episode.delete_rejected!("identifier", item.value)
        @episode.append_identifier!(item.value, correlation_id: @correlation_id, source: "user")
      end
    end

    # A controller brand fills an empty equipment manufacturer. It does not
    # replace one already stored.
    def controller_brand_replaces_equipment?(item)
      return false unless item.slot == "controller"

      current = @episode.fact("manufacturer")&.dig("value")
      return false if current.blank?

      FollowupQueryRewriter.normalize_label(current) != FollowupQueryRewriter.normalize_label(item.manufacturer)
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
      retracted_phrases.each { |phrase| excise_retracted_phrase(phrase) }
      return unless @turn.match?(/\bcorrijo\b/i)

      fresh = Array(@perception.observations).map { |text| text.to_s.squish }
      @episode.observations.reject! { |item|
        text = item["text"].to_s
        next false if fresh.any? { |phrase| same_label?(phrase, text) }

        fresh.any? { |phrase| observation_replaced?(text, phrase) }
      }
      adopt_problem_goal!(fresh)
    end

    # Sentence punctuation stops the retraction. "No lo sé" after the period
    # is not part of the replaced datum. A bare number is a shared digit, not
    # an observation to delete.
    def retracted_phrases
      @turn.to_s.scan(/\bno de\s+([^.;!?\n]+)/i).flatten.filter_map { |raw|
        tokens = FollowupQueryRewriter.normalize_label(raw).split.first(3)
        next if tokens.empty? || tokens.join(" ").match?(/\A\d+\z/)

        tokens.join(" ")
      }.uniq
    end

    def excise_retracted_phrase(phrase)
      pattern = token_pattern(phrase)
      @episode.observations.map! { |item|
        kept = independent_clauses(item["text"]).reject { |clause|
          FollowupQueryRewriter.normalize_label(clause).match?(pattern)
        }
        next if kept.empty?

        item.merge("text" => kept.join(" y "))
      }
      @episode.observations.compact!
      excise_retracted_goal(pattern)
    end

    def excise_retracted_goal(pattern)
      return unless @episode.goal.is_a?(Hash)

      text = @episode.goal["text"].to_s
      return unless FollowupQueryRewriter.normalize_label(text).match?(pattern)

      kept = independent_clauses(text).reject { |clause|
        FollowupQueryRewriter.normalize_label(clause).match?(pattern)
      }
      if kept.empty? || kept.none? { |clause| problem_statement?(clause) }
        @episode.clear_goal!
      else
        @episode.goal["text"] = kept.select { |clause| problem_statement?(clause) }.join(" y ")
      end
    end

    def independent_clauses(text)
      text.to_s.split(/\s+y\s+/i).map(&:squish).compact_blank
    end

    def same_label?(left, right)
      FollowupQueryRewriter.normalize_label(left) == FollowupQueryRewriter.normalize_label(right)
    end

    # Same sentence with one replaced word. A changed number is a different
    # referent unless the turn retracts it with "no de". Shared words alone
    # do not make two observations the same correction.
    def observation_replaced?(old_text, new_text)
      old_words = FollowupQueryRewriter.normalize_label(old_text).split
      new_words = FollowupQueryRewriter.normalize_label(new_text).split
      return false unless old_words.size == new_words.size && old_words.any?

      changed = old_words.zip(new_words).select { |left, right| left != right }
      return false unless changed.size == 1

      left, right = changed.first
      return false if numeric_token?(left) || numeric_token?(right)

      true
    end

    def numeric_token?(word)
      word.match?(/\A\d+\z/)
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
        next if phrase.blank? || ObservationText.continuity_echo?(phrase)

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

    # Symptom sentences are observations. Stored as identifiers they push the
    # equipment tokens out of the fixed list, and the prompt loses the machine
    # after the history trim.
    def durable_identifier?(value)
      words = value.to_s.squish.split
      return false if words.size >= 4

      label = FollowupQueryRewriter.normalize_label(value)
      return false if label.blank?
      return false if label.match?(/\A\d+\z/) && observation_mentions?(label)
      return false if observation_mentions?(label) && !label.match?(/\d/)

      true
    end

    def observation_mentions?(label)
      @perception.observations.any? { |text|
        FollowupQueryRewriter.normalize_label(text).match?(/(?<![[:alnum:]])#{Regexp.escape(label)}(?![[:alnum:]])/)
      }
    end

    def remove_identifier(value)
      label = FollowupQueryRewriter.normalize_label(value)
      @episode.identifiers.reject! { |item| FollowupQueryRewriter.normalize_label(item["value"]) == label }
    end

    def strip_value(value, slot:)
      return if value.blank?

      if @episode.goal.is_a?(Hash)
        text = SlotRejection.excise_text(@episode.goal["text"], slot, value)
        if text.blank?
          @episode.clear_goal!
        elsif text != @episode.goal["text"].to_s.squish
          @episode.goal["text"] = text
        end
      end
      @episode.observations.reject! { |item|
        SlotRejection.attributable?(item["text"], slot, value)
      }
      adopt_problem_goal! if slot.to_s == "fault_code"
    end

    # "El display muestra" is what remains after the code is removed. It is
    # not the job. A stored check becomes the goal only when the episode
    # already has one. A later explicit new job still opens its own episode.
    def adopt_problem_goal!(preferred = [])
      clear_residual_goal!
      return if problem_goal?

      phrase = Array(preferred).find { |text| problem_statement?(text) }
      row = if phrase
        { "text" => phrase, "correlation_id" => @correlation_id }
      else
        @episode.observations.find { |item| problem_statement?(item["text"]) }
      end
      return if row.nil?

      @episode.assign_goal!(row["text"], correlation_id: row["correlation_id"].presence || @correlation_id)
    end

    def clear_residual_goal!
      return unless @episode.goal.is_a?(Hash)
      return if problem_statement?(@episode.goal["text"])

      @episode.clear_goal!
    end

    def problem_goal?
      @episode.goal.is_a?(Hash) && problem_statement?(@episode.goal["text"])
    end

    def problem_statement?(text)
      normalized = FollowupQueryRewriter.normalize_label(text)
      return false if normalized.blank?

      TechnicalUnderstanding::SIGNAL_RE.match?(normalized)
    end

    def token_pattern(value)
      /(?<![[:alnum:]])#{Regexp.escape(value.to_s)}(?![[:alnum:]])/i
    end
  end
end
