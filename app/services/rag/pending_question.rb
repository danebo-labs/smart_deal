# frozen_string_literal: true

module Rag
  # Machine-readable question Ruby already knows it asked. No model call.
  module PendingQuestion
    TYPES = %w[fault_code manufacturer model controller choice absent work_relation referent correction_target].freeze
    CONVERSATIONAL_TYPES = %w[work_relation referent correction_target].freeze
    MAX_CARRY = 2
    FACT_TYPES = %w[fault_code manufacturer model controller].freeze
    CHOICE_OPENING = %w[opening closing].freeze

    module_function

    def coerce(raw)
      return nil unless raw.is_a?(Hash)

      type = raw["type"].to_s
      return nil unless TYPES.include?(type)

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

      nil
    end

    def sanitize_carry(raw)
      return [] unless raw.is_a?(Array)

      raw.filter_map { |item|
        text = item.to_s.strip
        next if text.blank? || text.length > ActiveEpisode::MAX_VALUE_CHARS

        text
      }.uniq.first(MAX_CARRY)
    end
  end
end
