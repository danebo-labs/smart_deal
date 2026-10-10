# frozen_string_literal: true

module Rag
  # Raw turn_perception payload check for the interpreter experiment.
  # It does not call TurnPerception.build, so it does not drop spans,
  # clear pending_resolution, or null an unknown slot_hint and then pass.
  class InterpreterPayloadContract
    def self.evaluate(tool_input, sent_turn:)
      new(tool_input, sent_turn).evaluate
    end

    def initialize(tool_input, sent_turn)
      @tool_input = tool_input
      @sent_turn = sent_turn.to_s
    end

    def evaluate
      return invalid("not_a_hash") unless @tool_input.is_a?(Hash)

      data = @tool_input.deep_stringify_keys
      failure = TurnPerception.structural_failure(data)
      return invalid(failure) if failure

      missing = TurnPerception::ROOT_KEYS - data.keys
      return invalid("missing_#{missing.first}") if missing.any?
      return invalid("over_length") if TurnPerception.over_length?(data)

      hint = slot_hint_failure(data)
      return invalid(hint) if hint
      pending = pending_failure(data)
      return invalid(pending) if pending
      literal = literal_failure(data)
      return invalid(literal) if literal

      { "valid" => true, "reason" => nil }
    end

    private

    def invalid(reason)
      { "valid" => false, "reason" => reason }
    end

    def slot_hint_failure(data)
      data["assertions"].each do |item|
        next unless item.key?("slot_hint")

        hint = item["slot_hint"]
        next if hint.nil? || TurnPerception::HINTS.include?(hint)

        return "invalid_slot_hint"
      end
      nil
    end

    def pending_failure(data)
      resolution = data["pending_resolution"]
      if data["move"] == "answer_pending"
        return "pending_incompatible" unless TurnPerception::RESOLUTIONS.include?(resolution)
        return "pending_value_without_assert" if resolution == "value" && !assert_span?(data)

        return nil
      end
      return "pending_incompatible" unless resolution.nil?

      nil
    end

    def assert_span?(data)
      data["assertions"].any? { |item| item["act"] == "assert" && item["span"].is_a?(String) && item["span"] != "" }
    end

    def literal_failure(data)
      data["assertions"].each do |item|
        return "span_not_literal" unless TurnPerception.literal_fragment?(item["span"], @sent_turn)
      end
      data["observations"].each do |text|
        return "observation_not_literal" unless TurnPerception.literal_fragment?(text, @sent_turn)
      end
      nil
    end
  end
end
