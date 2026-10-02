# frozen_string_literal: true

module Rag
  # Retrieval string from the episode after the reducer. The model does not write it.
  class QueryComposer
    def self.call(state:, turn:, perception:, decision:)
      new(state: state, turn: turn, perception: perception, decision: decision).call
    end

    def initialize(state:, turn:, perception:, decision:)
      @state = state
      @turn = turn.to_s
      @perception = perception
      @decision = decision
    end

    def call
      return nil if @decision.nil? || %w[meta clarify_first].include?(@decision.decision)

      parts = []
      push(parts, current_turn)
      push(parts, fact_value("fault_code"))
      push(parts, fact_value("controller"))
      push(parts, fact_value("model"))
      identifier_values.each { |value| push(parts, value) }
      push(parts, fact_value("manufacturer"))
      observations.each { |text| push(parts, text) }
      push(parts, goal_text)
      fit(parts)
    end

    private

    def current_turn
      return nil if @perception&.move == "answer_pending" && %w[unknown absent seek].include?(@perception.pending_resolution)

      text = @turn.dup
      Array(@perception&.identities).select { |item| item.kind == "negate" }.each do |item|
        text = text.sub(/#{Regexp.escape(item.span)}/i, " ")
      end
      rejected_values.each do |value|
        text = text.sub(/#{Regexp.escape(value)}/i, " ")
      end
      text.squish.presence
    end

    def fact_value(key)
      fact = @state.fact(key)
      return nil unless fact.is_a?(Hash) && fact["status"] == "known"

      value = fact["value"].to_s
      return nil if rejected?(key, value)

      value
    end

    def identifier_values
      Array(@state.identifiers).filter_map { |item|
        value = item["value"].to_s
        next if value.blank? || rejected?("identifier", value)

        value
      }
    end

    def observations
      Array(@state.observations).reverse.filter_map { |item|
        text = item["text"].to_s
        next if text.blank? || rejected_values.any? { |value| text.downcase.include?(value.downcase) }

        text
      }.first(ActiveEpisode::MAX_OBSERVATIONS)
    end

    def goal_text
      text = @state.goal&.dig("text").to_s
      return nil if text.blank? || rejected_values.any? { |value| text.downcase.include?(value.downcase) }

      text
    end

    def rejected_values
      @rejected_values ||= Array(@state.respond_to?(:rejected) ? @state.rejected : []).filter_map { |item| item["value"].presence }
    end

    def rejected?(slot, value)
      label = FollowupQueryRewriter.normalize_label(value)
      Array(@state.rejected).any? { |item|
        item["slot"] == slot && FollowupQueryRewriter.normalize_label(item["value"]) == label
      }
    end

    def push(parts, text)
      label = FollowupQueryRewriter.normalize_label(text)
      return if label.blank?
      return if parts.any? { |part| FollowupQueryRewriter.normalize_label(part) == label }

      parts << text.to_s.squish
    end

    def fit(parts)
      while parts.any? && parts.join(" ").length > FollowupQueryRewriter::MAX_COMPOSED_CHARS
        parts.pop
      end
      joined = parts.join(" ").squish
      joined.presence
    end
  end
end
