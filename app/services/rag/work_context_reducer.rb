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

      if @decision&.decision == "clarify_first"
        write_pending(@decision.pending_question)
        @episode.touch!(@now)
        return @episode
      end
      return @episode if @perception.move == "unclear"

      promote_carry if answer_promotes_carry?
      apply_negations
      write_assertions
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
    end

    def assign_goal_if_needed
      return if @episode.goal.present?
      return unless @decision&.performs_retrieval?
      return unless %w[report follow_up new_work].include?(@perception.move)

      @episode.assign_goal!(@turn, correlation_id: @correlation_id)
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

      pattern = /#{Regexp.escape(value)}/i
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
  end
end
