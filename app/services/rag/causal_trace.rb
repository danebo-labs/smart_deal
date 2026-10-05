# frozen_string_literal: true

module Rag
  # Bounded tokens for one correlation. Reads decisions the turn already made.
  # It does not retrieve, generate, or write the episode.
  module CausalTrace
    ITEM_LIMIT = 120
    TRUNCATED = ":truncated"

    module_function

    def assertion_tokens(perception, decision, fallback: false)
      return nil if perception.nil?

      reason = short_circuit_reason(perception, decision, fallback: fallback)
      tokens = []
      Array(perception.identities).each do |item|
        tokens << assertion_token(
          act: item.act,
          kind: item.kind,
          slot: item.slot,
          span: item.span,
          status: identity_status(item, reason)
        )
      end
      Array(perception.observations).each do |text|
        tokens << assertion_token(
          act: "observe",
          kind: "observation",
          slot: nil,
          span: text,
          status: reason ? "ignored(#{reason})" : "applied"
        )
      end
      tokens.presence
    end

    def idle_query_components
      query_components(
        current_turn: "dropped",
        identity: false,
        identifiers: false,
        observations: 0,
        photo: false,
        goal: false,
        truncated: false
      )
    end

    def query_components(current_turn:, identity:, identifiers:, observations:, photo:, goal:, truncated:)
      [
        "current_turn:#{current_turn}",
        "identity:#{identity ? "present" : "absent"}",
        "identifiers:#{identifiers ? "present" : "absent"}",
        "observations:#{observations.to_i}",
        "photo:#{photo ? "present" : "absent"}",
        "goal:#{goal ? "present" : "absent"}",
        "truncated:#{truncated ? "true" : "false"}"
      ]
    end

    def generation_fields(text:, raw_turn:, sent_question:, truncated:)
      body = text.to_s
      return {} if body.blank?

      {
        generation_context: generation_context_tokens(body, raw_turn, sent_question),
        generation_prompt_chars: body.length,
        context_truncated: truncated == true
      }
    end

    def resolved_generation_mode(explicit, success:)
      return explicit if explicit.present?
      return "generative" if success

      nil
    end

    def assertion_token(act:, kind:, slot:, span:, status:)
      prefix = "#{act}:#{kind}:#{slot}:#{status}:"
      bounded(prefix, span.to_s)
    end

    def short_circuit_reason(perception, decision, fallback:)
      return "fallback" if fallback || decision.nil?
      return "meta" if decision.decision == "meta"
      return "clarify_first" if decision.decision == "clarify_first"
      return "unclear" if perception.move == "unclear"

      nil
    end

    def identity_status(item, reason)
      return "ignored(#{reason})" if reason
      return (item.slot.present? ? "applied" : "ignored(no_slot)") if item.kind == "negate"
      return "ignored(not_written)" if item.kind == "mention" || item.act == "mention"

      "applied"
    end

    def generation_context_tokens(text, raw_turn, sent_question)
      photo = photo_band(text)
      [
        "technician_current_turn:#{current_turn_band(text, raw_turn, sent_question)}",
        "technician_facts_count:#{technician_facts_count(text)}",
        "observations_count:#{observations_count(text)}",
        "photo_literal:#{photo}",
        "photo_interpretation:#{photo}",
        "compatible_docs_count:#{text.scan("THIS JOB'S EQUIPMENT:").length}",
        "foreign_reference_docs_count:#{foreign_reference_count(text)}",
        "danebo_guidance:#{text.include?("# FIELD COMPANION") ? "present" : "absent"}"
      ]
    end

    def current_turn_band(text, raw_turn, sent_question)
      if raw_turn.nil?
        return "absent" if sent_question.to_s.blank? && text.blank?

        return "present"
      end

      raw = raw_turn.to_s.squish
      return "absent" if raw.blank?
      return "present" if text.include?(raw) || sent_question.to_s.squish == raw

      "absent"
    end

    def technician_facts_count(text)
      text.scan(/^Known equipment identity: /).length +
        text.scan(/^(?:Manufacturer|Model|Controller|Fault code): .+\((?:technician|catalog|user|photo)\)/).length
    end

    def observations_count(text)
      block = text[/Technician observations:\n(.*?)(?:\n(?:[A-Z#])|\z)/m, 1]
      return 0 if block.blank?

      block.scan(/^- /).length
    end

    def foreign_reference_count(text)
      count = text.scan("REFERENCE ONLY — OTHER EQUIPMENT:").length
      names = text[/Reference-only manuals, names only: ([^.]+)/, 1]
      count += names.split(";").count { |name| name.squish.present? } if names
      count
    end

    def photo_band(text)
      return "absent" unless text.include?("Photo Evidence") ||
        text.include?("Read from the active episode photo") ||
        text.include?("Read from the photo, not stated")

      "mixed"
    end

    def bounded(prefix, span)
      full = "#{prefix}#{span}"
      return full if full.length <= ITEM_LIMIT

      room = ITEM_LIMIT - prefix.length - TRUNCATED.length
      room = 0 if room.negative?
      "#{prefix}#{span.first(room)}#{TRUNCATED}"
    end
    private_class_method :assertion_token, :short_circuit_reason, :identity_status,
      :generation_context_tokens, :current_turn_band, :technician_facts_count,
      :observations_count, :foreign_reference_count, :photo_band, :bounded
  end
end
