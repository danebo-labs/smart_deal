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
      fault_code = fact_value("fault_code")
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

    def photo_terms
      context = @active_photo_context
      return [] if context.nil? || !@decision&.performs_retrieval?
      return [] unless context.matches?(@state.active_photo&.dig("field_photo_id"))

      context.query_terms
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

    def idle?
      @decision.nil? || %w[meta clarify_first].include?(@decision.decision)
    end

    def push(parts, text)
      label = FollowupQueryRewriter.normalize_label(text)
      return if label.blank?
      return if parts.any? { |part| FollowupQueryRewriter.normalize_label(part) == label }

      parts << text.to_s.squish
    end

    def push_role(parts, roles, text, role)
      before = parts.length
      push(parts, text)
      roles << role if parts.length > before
    end

    def fit(parts, roles)
      @truncated = false
      while parts.any? && parts.join(" ").length > FollowupQueryRewriter::MAX_COMPOSED_CHARS
        parts.pop
        roles.pop
        @truncated = true
      end
      joined = parts.join(" ").squish
      joined.presence
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
