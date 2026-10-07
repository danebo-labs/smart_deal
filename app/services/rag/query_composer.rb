# frozen_string_literal: true

module Rag
  # Retrieval string from the episode after the reducer. The model does not write it.
  class QueryComposer
    def self.call(state:, turn:, perception:, decision:, active_photo_context: nil)
      explain(
        state: state, turn: turn, perception: perception, decision: decision,
        active_photo_context: active_photo_context
      )[:query]
    end

    def self.explain(state:, turn:, perception:, decision:, active_photo_context: nil)
      composer = new(
        state: state, turn: turn, perception: perception, decision: decision,
        active_photo_context: active_photo_context
      )
      { query: composer.call, components: composer.components }
    end

    def initialize(state:, turn:, perception:, decision:, active_photo_context: nil)
      @state = state
      @turn = turn.to_s
      @perception = perception
      @decision = decision
      @active_photo_context = active_photo_context
      @components = nil
    end

    attr_reader :components

    def call
      if idle?
        @components = safe_components { CausalTrace.idle_query_components }
        return nil
      end

      parts = []
      roles = []
      fault_code = fault_code_text
      controller = fact_value("controller")
      model = fact_value("model")
      identifier_list = identifier_values
      manufacturer = fact_value("manufacturer")
      observation_list = observations
      photo_list = photo_terms
      goal = goal_text
      push_role(parts, roles, current_turn, :current_turn)
      push_role(parts, roles, fault_code, :identity)
      push_role(parts, roles, controller, :identity)
      push_role(parts, roles, model, :identity)
      identifier_list.each { |value| push_role(parts, roles, value, :identifier) }
      push_role(parts, roles, manufacturer, :identity)
      observation_list.each { |text| push_role(parts, roles, text, :observation) }
      photo_list.each { |term| push_role(parts, roles, term, :photo) }
      push_role(parts, roles, goal, :goal)
      query = fit(parts, roles)
      @components = safe_components {
        component_tokens(
          parts, roles,
          identity_values: [ fault_code, controller, model, manufacturer ].compact,
          identifier_values: identifier_list,
          observation_values: observation_list,
          photo_values: photo_list,
          goal_value: goal,
          truncated: @truncated
        )
      }
      query
    end

    private

    def current_turn
      return nil if @perception&.move == "answer_pending" && %w[unknown absent seek].include?(@perception.pending_resolution)

      text = @turn.dup
      Array(@perception&.identities).select { |item| item.kind == "negate" }.each do |item|
        text = excise_negation(text, item)
      end
      text = strip_rejected_phrases(text)
      tidy(text).presence
    end

    def excise_negation(text, item)
      value = item.value.presence || item.span
      return SlotRejection.excise_text(text, "fault_code", value) if item.slot == "fault_code"
      return text if value.to_s.match?(/\A\d+\z/)

      excise(text, item.span.presence || value)
    end

    def strip_rejected_phrases(text)
      Array(@state.rejected).each do |item|
        text = SlotRejection.excise_text(text, item["slot"], item["value"])
      end
      text
    end

    def tidy(text)
      cleaned = text.to_s
      cleaned = cleaned.gsub(/[ \t]+([,.;:])/, '\1')
      cleaned = cleaned.gsub(/[,:;]\s*\./, ".")
      cleaned = cleaned.gsub(/\s+/, " ")
      cleaned.sub(/\A\s*[,.;:]+\s*/, "").sub(/\s*[,:;]\s*\z/, "").strip
    end

    # A numeric fault code is invisible to the harness unless the retrieval
    # string contains "código N". The prefix is the retrieval form of the
    # stored value, not a meaning for that code.
    def fault_code_text
      value = fact_value("fault_code")
      return nil if value.blank?

      value.match?(/\A\d+\z/) ? "código #{value}" : value
    end

    def excise(text, value)
      return text if value.blank?

      text.gsub(token_pattern(value), " ")
    end

    def token_pattern(value)
      /(?<![[:alnum:]])#{Regexp.escape(value.to_s)}(?![[:alnum:]])/i
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
      rows = Array(@state.observations)
      labels = rows.map { |item| ObservationText.normalize(item["text"]) }
      seen = []
      rows.reverse.filter_map { |item|
        text = item["text"].to_s
        next if text.blank? || rejected_observation?(text)
        next if ObservationText.continuity_echo?(text) || ObservationText.trailing_echo?(text, labels)

        label = ObservationText.normalize(text)
        next if seen.include?(label) || covered_by_goal_or_turn?(text)

        seen << label
        text
      }.first(ActiveEpisode::MAX_STORED_OBSERVATIONS)
    end

    def rejected_observation?(text)
      Array(@state.rejected).any? { |item| SlotRejection.attributable?(text, item["slot"], item["value"]) }
    end

    def covered_by_goal_or_turn?(text)
      ObservationText.covered_by?(goal_source, text) || ObservationText.covered_by?(cleaned_turn, text)
    end

    def goal_source
      @state.goal&.dig("text").to_s
    end

    def cleaned_turn
      @cleaned_turn ||= current_turn.to_s
    end

    def photo_terms
      context = @active_photo_context
      return [] if context.nil? || !@decision&.performs_retrieval?
      return [] unless context.matches?(@state.active_photo&.dig("field_photo_id"))

      context.query_terms
    end

    def goal_text
      text = goal_source
      return nil if text.blank?

      Array(@state.rejected).each do |item|
        text = SlotRejection.excise_text(text, item["slot"], item["value"])
      end
      return nil if text.blank? || said_in_turn?(text)

      text
    end

    def said_in_turn?(text)
      return true if ObservationText.covered_by?(cleaned_turn, text)

      holder = ObservationText.normalize(cleaned_turn).gsub(" y ", " ")
      phrase = ObservationText.normalize(text).gsub(" y ", " ")
      phrase.present? && holder.match?(/(?<![[:alnum:]])#{Regexp.escape(phrase)}(?![[:alnum:]])/)
    end

    def rejected?(slot, value)
      label = FollowupQueryRewriter.normalize_label(value)
      Array(@state.rejected).any? { |item|
        item["slot"] == slot && FollowupQueryRewriter.normalize_label(item["value"]) == label
      }
    end

    def idle?
      @decision.nil? || %w[meta clarify_first].include?(@decision.decision)
    end

    def push(parts, text)
      label = FollowupQueryRewriter.normalize_label(text)
      return if label.blank?

      joined = FollowupQueryRewriter.normalize_label(parts.join(" "))
      return if joined.match?(/(?<![[:alnum:]])#{Regexp.escape(label)}(?![[:alnum:]])/)

      parts << text.to_s.squish
    end

    def push_role(parts, roles, text, role)
      before = parts.length
      push(parts, text)
      roles << role if parts.length > before
    end

    def fit(parts, roles)
      @truncated = false
      while over_budget?(parts)
        index = roles.rindex(:observation) || roles.rindex(:photo)
        break unless index

        parts.delete_at(index)
        roles.delete_at(index)
        @truncated = true
      end
      while over_budget?(parts)
        parts.pop
        roles.pop
        @truncated = true
      end
      parts.join(" ").squish.presence
    end

    def over_budget?(parts)
      parts.any? && parts.join(" ").length > FollowupQueryRewriter::MAX_COMPOSED_CHARS
    end

    def component_tokens(parts, roles, identity_values:, identifier_values:, observation_values:, photo_values:, goal_value:, truncated:)
      labels = parts.map { |part| FollowupQueryRewriter.normalize_label(part) }
      turn_index = roles.index(:current_turn)
      current = if turn_index.nil?
        "dropped"
      elsif labels[turn_index] == FollowupQueryRewriter.normalize_label(@turn)
        "full"
      else
        "partial"
      end
      CausalTrace.query_components(
        current_turn: current,
        identity: included?(labels, identity_values),
        identifiers: included?(labels, identifier_values),
        observations: Array(observation_values).count { |value| labels.include?(FollowupQueryRewriter.normalize_label(value)) },
        photo: included?(labels, photo_values),
        goal: included?(labels, [ goal_value ]),
        truncated: truncated
      )
    end

    def included?(labels, values)
      Array(values).any? { |value| labels.include?(FollowupQueryRewriter.normalize_label(value)) }
    end

    def safe_components
      yield
    rescue StandardError => error
      Rails.logger.warn("query component trace failed #{error.class}")
      nil
    end
  end
end
