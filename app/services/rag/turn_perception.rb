# frozen_string_literal: true

module Rag
  # What the technician said. Ruby checks the tool payload and the catalog.
  # Document Focus is not an input: RoutePolicy decides what to do with it.
  class TurnPerception
    MOVES = %w[report follow_up answer_pending correct new_work meta unclear].freeze
    ACTS = %w[assert negate mention].freeze
    HINTS = %w[manufacturer model controller fault_code designator].freeze
    RESOLUTIONS = %w[unknown absent value seek].freeze
    FACT_SLOTS = %w[manufacturer model controller fault_code].freeze
    IDENTITY_HINTS = %w[manufacturer model controller].freeze
    CLARIFICATION_TARGETS = %w[work_relation referent correction_target].freeze
    ROOT_KEYS = %w[move assertions observations pending_resolution clarification_target].freeze
    ASSERTION_KEYS = %w[span act slot_hint].freeze
    MAX_ASSERTIONS = 8
    MAX_TOOL_BYTES = 4096
    MIN_OBSERVATION_CHARS = 13
    FAULT_RE = /\A[a-z]?\d{1,4}[a-z]?\z/
    PROMPT_VERSION = "2026-10-02.6"
    SCHEMA_VERSION = "turn_perception.3"

    Identity = Data.define(:span, :act, :kind, :slot, :value, :source, :manufacturer)
    Ambiguity = Data.define(:span, :candidates)

    Result = Data.define(
      :valid, :move, :observations, :pending_resolution, :clarification_target,
      :identities, :ambiguities, :field_rejections, :catalog_disagreements, :invalid_reason
    ) do
      def facts
        identities.select { |item| item.kind == "fact" }
      end

      def identifiers
        identities.select { |item| item.kind == "identifier" }
      end

      def mentions
        identities.select { |item| item.kind == "mention" }
      end

      def technical_payload?
        observations.any? || ambiguities.any? || identities.any? { |item|
          item.kind == "fact" || (item.act == "assert" && item.kind == "identifier")
        }
      end
    end

    def self.build(raw, turn:, episode:, catalog:, viewer_account:)
      new(raw: raw, turn: turn, episode: episode, catalog: catalog, viewer_account: viewer_account).build
    end

    def self.tool_schema
      {
        type: "object",
        additionalProperties: false,
        required: ROOT_KEYS,
        properties: {
          move: { type: "string", enum: MOVES },
          assertions: {
            type: "array",
            maxItems: MAX_ASSERTIONS,
            items: {
              type: "object",
              additionalProperties: false,
              required: %w[span act],
              properties: {
                span: { type: "string", maxLength: ActiveEpisode::MAX_VALUE_CHARS },
                act: { type: "string", enum: ACTS },
                slot_hint: { type: %w[string null] }
              }
            }
          },
          observations: {
            type: "array",
            maxItems: ActiveEpisode::MAX_OBSERVATIONS,
            items: { type: "string", maxLength: ActiveEpisode::MAX_OBSERVATION_CHARS }
          },
          pending_resolution: { type: %w[string null] },
          clarification_target: { type: %w[string null] }
        }
      }
    end

    def initialize(raw:, turn:, episode:, catalog:, viewer_account:)
      @raw = raw
      @turn = TurnText.truncate(turn)
      @episode = episode || ActiveEpisode.new
      @catalog = catalog
      @viewer_account = viewer_account
      @field_rejections = []
      @catalog_disagreements = []
    end

    def build
      data = coerce_tool(@raw)
      return invalid("invalid_schema") if data.nil?
      return invalid("over_length") if over_length?(data)

      assertions = literal_assertions(data["assertions"])
      observations = literal_observations(data["observations"])
      identities, ambiguities = resolve_assertions(assertions, observations)
      move = data["move"]
      resolution = data["pending_resolution"]
      move, resolution, identities, observations, ambiguities, target = adjust_move(
        move, resolution, identities, observations, ambiguities, data["clarification_target"]
      )
      resolution = nil unless move == "answer_pending"
      identities = apply_structured_slots(move, resolution, identities)

      Result.new(
        valid: true,
        move: move,
        observations: observations,
        pending_resolution: resolution,
        clarification_target: target,
        identities: identities,
        ambiguities: ambiguities,
        field_rejections: @field_rejections,
        catalog_disagreements: @catalog_disagreements,
        invalid_reason: nil
      )
    end

    private

    def coerce_tool(raw)
      return nil unless raw.is_a?(Hash)

      data = raw.deep_stringify_keys
      return nil if (data.keys - ROOT_KEYS).any?
      return nil unless MOVES.include?(data["move"])
      return nil unless data["assertions"].is_a?(Array) && data["observations"].is_a?(Array)
      return nil if data["assertions"].size > MAX_ASSERTIONS
      return nil if data["observations"].size > ActiveEpisode::MAX_OBSERVATIONS
      return nil unless data["pending_resolution"].nil? || RESOLUTIONS.include?(data["pending_resolution"])
      return nil unless clarification_target_ok?(data)
      return nil unless data["assertions"].all? { |item| assertion_shape?(item) }
      return nil unless data["observations"].all? { |item| item.is_a?(String) }
      return nil if JSON.generate(data).bytesize > MAX_TOOL_BYTES

      data["assertions"] = data["assertions"].map { |item| normalize_assertion(item.deep_stringify_keys) }
      data
    end

    def clarification_target_ok?(data)
      return false unless data.key?("clarification_target")

      target = data["clarification_target"]
      return false unless target.nil? || CLARIFICATION_TARGETS.include?(target)
      return false if data["move"] == "unclear" && target.nil?
      return false if data["move"] != "unclear" && !target.nil?

      true
    end

    def assertion_shape?(item)
      return false unless item.is_a?(Hash)

      keys = item.keys.map(&:to_s)
      return false if (keys - ASSERTION_KEYS).any?
      return false unless item["span"].is_a?(String) || item[:span].is_a?(String)
      return false unless ACTS.include?(item["act"] || item[:act])

      true
    end

    def normalize_assertion(item)
      hint = item["slot_hint"]
      if hint.nil? || HINTS.include?(hint)
        item
      else
        reject_field("slot_hint", "unknown_hint")
        item.merge("slot_hint" => nil)
      end
    end

    def over_length?(data)
      data["assertions"].any? { |item| item["span"].length > ActiveEpisode::MAX_VALUE_CHARS } ||
        data["observations"].any? { |item| item.length > ActiveEpisode::MAX_OBSERVATION_CHARS }
    end

    def literal_assertions(assertions)
      assertions.filter_map.with_index do |item, index|
        if literal_span?(item["span"])
          item
        else
          reject_field("assertions[#{index}].span", "not_literal")
          nil
        end
      end
    end

    def literal_observations(observations)
      observations.filter_map.with_index do |text, index|
        phrase = text.to_s.strip
        if !literal_span?(phrase)
          reject_field("observations[#{index}]", "not_literal")
          nil
        elsif symptom_observation?(phrase)
          phrase
        else
          reject_field("observations[#{index}]", "not_symptom")
          nil
        end
      end
    end

    # A literal multi-word phrase can be a short field symptom. A single token
    # is not an observation when it is a code, a short token, or under the floor.
    def symptom_observation?(text)
      tokens = text.to_s.squish.split(/\s+/)
      return false if tokens.empty?
      return true if tokens.many?

      !lone_technical_token?(tokens.first)
    end

    def lone_technical_token?(token)
      token.match?(FAULT_RE) || short_token?(token) || token.length < MIN_OBSERVATION_CHARS
    end

    def literal_span?(span)
      candidate = normalize_span(span).sub(/\A\p{P}+/u, "").sub(/\p{P}+\z/u, "")
      return false if candidate.empty?

      normalize_span(@turn).include?(candidate)
    end

    def normalize_span(value)
      value.to_s.unicode_normalize(:nfc).downcase.gsub(/[[:space:]]+/, " ").strip
    end

    def short_token?(text)
      tokens = text.to_s.squish.split(/\s+/)
      tokens.one? && tokens.first.match?(/\A[\p{L}\d]{2,4}\z/)
    end

    def resolve_assertions(assertions, observations)
      draft = assertions.map { |item| catalog_identity(item) }
      context = fault_context?(draft.compact, observations)
      identities = []
      ambiguities = []
      assertions.each_with_index do |item, index|
        found = draft[index] || remainder_identity(item, context)
        if found.is_a?(Ambiguity)
          ambiguities << found
        else
          identities << found
        end
      end
      [ identities, ambiguities ]
    end

    def catalog_identity(item)
      return negate_identity(item) if item["act"] == "negate"

      designator = lookup_designator(item["span"])
      return nil if designator.nil?
      return Ambiguity.new(span: item["span"], candidates: designator.candidates) if designator.status == :ambiguous
      return nil unless designator.status == :exact || designator.status == :prefix

      typed_designator(item, designator)
    end

    def typed_designator(item, designator)
      slot = designator.type.to_s
      if %w[controller model].include?(slot) && designator.value.present?
        disagree(item["span"], item["slot_hint"], slot)
        return fact(item["span"], item["act"], slot, designator.value, "catalog", designator.manufacturer)
      end

      identifier(item["span"], item["act"])
    end

    def remainder_identity(item, context)
      return negate_identity(item) if item["act"] == "negate"

      brand = lookup_brand(item["span"])
      if brand&.status == :exact
        disagree(item["span"], item["slot_hint"], "manufacturer")
        return fact(item["span"], item["act"], "manufacturer", brand.manufacturer, "catalog", brand.manufacturer)
      end

      span = item["span"]
      hint = item["slot_hint"]
      if fault_shaped?(span) && (hint == "fault_code" || pending_slot == "fault_code") && context
        disagree(span, hint, "fault_code")
        return fact(span, "assert", "fault_code", span, "user", nil)
      end
      return mention(span) if fault_shaped?(span)

      disagree(span, hint, nil) if IDENTITY_HINTS.include?(hint)
      return mention(span) if item["act"] == "mention"

      identifier(span, item["act"])
    end

    def negate_identity(item)
      Identity.new(
        span: item["span"], act: "negate", kind: "negate",
        slot: matched_slot(item["span"]), value: item["span"], source: nil, manufacturer: nil
      )
    end

    def fact(span, act, slot, value, source, manufacturer)
      Identity.new(
        span: span, act: act, kind: "fact", slot: slot, value: value,
        source: source, manufacturer: manufacturer
      )
    end

    def identifier(span, act)
      Identity.new(span: span, act: act, kind: "identifier", slot: nil, value: span, source: nil, manufacturer: nil)
    end

    def mention(span)
      Identity.new(span: span, act: "mention", kind: "mention", slot: nil, value: span, source: nil, manufacturer: nil)
    end

    def fault_context?(draft, observations)
      return true if pending_slot == "fault_code"
      return true if observations.any?

      draft.compact.any? { |item|
        item.is_a?(Identity) && item.kind == "fact" && %w[manufacturer model controller].include?(item.slot)
      }
    end

    def fault_shaped?(span)
      FollowupQueryRewriter.normalize_label(span).match?(FAULT_RE)
    end

    def lookup_designator(span)
      return nil if @viewer_account.nil? || @catalog.nil?

      @catalog.resolve_designator(span, viewer_account: @viewer_account)
    end

    def lookup_brand(span)
      return nil if @viewer_account.nil? || @catalog.nil?

      @catalog.resolve_brand(span, viewer_account: @viewer_account)
    end

    def pending_slot
      question = @episode.respond_to?(:pending_question) ? @episode.pending_question : nil
      if question.is_a?(Hash) && ActiveEpisode::PENDING_SUBJECTS.include?(question["type"].to_s)
        return question["type"].to_s
      end

      subject = @episode.respond_to?(:pending_fact) ? @episode.pending_fact&.dig("subject").to_s : ""
      return subject if ActiveEpisode::PENDING_SUBJECTS.include?(subject)

      nil
    end

    def matched_slot(span)
      label = FollowupQueryRewriter.normalize_label(span)
      return nil if label.blank? || !@episode.respond_to?(:fact)

      ActiveEpisode::FACT_KEYS.each do |key|
        fact = @episode.fact(key)
        next unless fact.is_a?(Hash) && fact["status"] == "known"
        return key if FollowupQueryRewriter.normalize_label(fact["value"]) == label
      end
      return "identifier" if Array(@episode.identifiers).any? { |item|
        FollowupQueryRewriter.normalize_label(item["value"]) == label
      }

      nil
    end

    def adjust_move(move, resolution, identities, observations, ambiguities, target)
      if move == "answer_pending" && !pending_answer?(resolution, identities)
        move = identities.any? || observations.any? || ambiguities.any? ? "report" : "follow_up"
        resolution = nil
      elsif move == "correct" && identities.none? { |item| item.kind == "negate" && item.slot.present? }
        move = "unclear"
        target = "correction_target"
        resolution = nil
        identities = []
        observations = []
      elsif move == "new_work" && !self.class.technical_payload?(identities, observations, ambiguities) && prior_context? && !work_relation_pending?
        move = "follow_up"
      end
      target = nil unless move == "unclear"
      [ move, resolution, identities, observations, ambiguities, target ]
    end

    def self.technical_payload?(identities, observations, ambiguities)
      observations.any? || ambiguities.any? || identities.any? { |item|
        item.kind == "fact" || (item.act == "assert" && item.kind == "identifier")
      }
    end

    def work_relation_pending?
      @episode.respond_to?(:pending_question) && @episode.pending_question&.dig("type") == "work_relation"
    end

    def pending_answer?(resolution, identities)
      slot = pending_slot
      return false if slot.nil? || resolution.nil?
      return value_matches?(identities, slot) if resolution == "value"
      return slot == "fault_code" if resolution == "absent"
      return %w[manufacturer model controller].include?(slot) if resolution == "unknown"

      resolution == "seek"
    end

    def value_matches?(identities, slot)
      asserts = identities.select { |item| item.act == "assert" }
      return false if asserts.empty?

      asserts.any? { |item| item.kind == "identifier" || (item.kind == "fact" && item.slot == slot) }
    end

    def prior_context?
      return false unless @episode.respond_to?(:blank?)
      return false if @episode.blank?

      @episode.goal.present? || @episode.facts.any? || @episode.identifiers.any? ||
        @episode.observations.any? || @episode.active_photo.present?
    end

    def apply_structured_slots(move, resolution, identities)
      if move == "answer_pending" && resolution == "value"
        type_pending_value(identities)
      elsif move == "correct"
        type_correction(identities)
      else
        identities
      end
    end

    def type_pending_value(identities)
      slot = pending_slot
      return identities if identities.any? { |item| item.kind == "fact" && item.slot == slot }

      typed = false
      identities.map { |item|
        next item if typed || item.kind != "identifier" || item.act != "assert"

        typed = true
        fact(item.span, "assert", slot, item.span, "user", nil)
      }
    end

    def type_correction(identities)
      negated = identities.find { |item| item.kind == "negate" && FACT_SLOTS.include?(item.slot) }
      return identities if negated.nil?

      replaced = false
      identities.map { |item|
        next item unless !replaced && item.kind == "identifier" && item.act == "assert"

        replaced = true
        fact(item.span, "assert", negated.slot, item.span, "user", nil)
      }
    end

    def disagree(span, hint, catalog_slot)
      return if hint.blank? || hint == "designator"
      return if hint == catalog_slot

      @catalog_disagreements << { "span" => span, "hint" => hint, "catalog" => catalog_slot }
    end

    def reject_field(field, reason)
      @field_rejections << { "field" => field, "reason" => reason }
    end

    def invalid(reason)
      Result.new(
        valid: false, move: nil, observations: [], pending_resolution: nil, clarification_target: nil,
        identities: [], ambiguities: [], field_rejections: @field_rejections,
        catalog_disagreements: [], invalid_reason: reason
      )
    end
  end
end
