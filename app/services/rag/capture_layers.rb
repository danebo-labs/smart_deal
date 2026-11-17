# frozen_string_literal: true

module Rag
  # Read the same stage events for both durable traces and case dialogue.
  module CaptureLayers
    QUERY_KINDS = %w[effective_query query_rewrite case_record_retrieval retrieve retrieve_attempt companion_turn_retrieve].freeze

    module_function

    def evidence(events)
      explicit = events.select do |event|
        event["kind"] == "generator_evidence" || event["delivered_to_generator"] == true ||
          (event["kind"] == "retrieval_results" && %w[generator generation delivered].include?(event["role"]))
      end
      return explicit if explicit.any?

      # Older direct captures recorded the numbered source roster and the
      # input to Converse. Recover the exact bodies from that input when it
      # exists. A retrieved candidate alone is not generator evidence.
      sources = events.reverse.find { |event| event["kind"] == "case_record_sources" }
      sent = events.select { |event| event["kind"] == "converse" && %w[companion_direct converse_message].include?(event["operation"]) }
      return [] unless sources && sent.any?

      sent.filter_map { |request| direct_evidence(request, sources) }
    end

    def direct_evidence(request, sources)
      message = Array(request["messages"]).last
      return unless message.is_a?(Hash) && message["role"] == "user"

      text = Array(message["content"]).filter_map { |block| block["text"] if block.is_a?(Hash) }.last
      return unless text.is_a?(String)

      suffix = text.split("\nFuentes de este turno:\n", 2).last
      return unless suffix && suffix != text

      bodies = suffix.scan(/^\[(\d+)\] [^\n]+\n(.*?)(?=\n\n\[\d+\] |\z)/m).to_h
      rows = Array(sources["sources"]).filter_map do |source|
        body = bodies[source["n"].to_s]&.strip
        source.merge("text" => body) if body.present?
      end
      return if rows.empty?

      request.slice("correlation_id", "attempt", "sequence").merge(
        "kind" => "generator_evidence", "stage" => "companion_direct",
        "provenance" => "observed", "source" => "converse.messages", "rows" => rows
      )
    end

    def model_outputs(events)
      events.filter_map do |event|
        case event["kind"]
        when "companion_direct"
          event["text"].presence
        when "companion_plan"
          event["tool_input"].presence
        when "converse", "retrieve_and_generate", "model_call"
          event["output"].presence || event["raw"].presence || event["completion"].presence
        end
      end
    end

    def captured?(value)
      !value.nil? && value != false && (!value.respond_to?(:empty?) || !value.empty?)
    end

    def companion_status(events, stage)
      matched = events.select { |event| event["kind"] == stage }
      key = stage == "companion_direct" ? "text" : "tool_input"
      return "present" if matched.any? { |event| captured?(event[key]) }
      return "uncaptured" if matched.any?

      other = stage == "companion_direct" ? "companion_plan" : "companion_direct"
      events.any? { |event| event["kind"] == other } ? "not_executed" : "unobserved"
    end
  end
end
