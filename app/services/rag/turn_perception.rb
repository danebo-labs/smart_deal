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
    IDENTITY_HEDGE = /
      \b(?:creo|me\s+parece|puede\s+ser|podria(?:\s+ser)?|quizas|tal\s+vez|
      no\s+se\s+si|no\s+estoy\s+seguro)\b
    /ix
    PROMPT_VERSION = "2026-10-07.2"
    SCHEMA_VERSION = "turn_perception.3"
    # Markers already used to separate a lone evidence offer from a mixed turn.
    # They are not the definition of a technical question.
    TECHNICAL_MARKER = /\b(?:resum|observacion|falla|codigo|puerta|sintoma)\b/
    COURTESY_TOKEN = /\A(?:que|tal|estas|esta|como|va|bien|todo|buenos|buena|perfecto|entendido)\z/
    PRODUCT_OPERATION = /\b(?:uso|usar|usas|funciona|sirve|selecciono|seleccionar|selecciona|elijo|elegir|elige)\b/
    # Using or choosing the manual in the product. Not a question about a drawing.
    MANUAL_SELECTION = /\b(?:uso|usar|usas|selecciono|seleccionar|selecciona|elijo|elegir|elige)\b/
    PRODUCT_DOCUMENT = /\b(?:manual|documento)\b/
    MEDIA_TOKEN = /\A(?:foto|imagen|video)\z/
    # Offer-frame words only. Equipment words are not added here.
    LONE_OFFER_TOKEN = /\A(?:puedo|puedes|tengo|enviarte|envio|enviar|te|si|otra|una|un|la|el|de|mi|foto|imagen|video|mando|mandarte|adjunto|esta|este|por|favor|sirve)\z/

    Identity = Data.define(:span, :act, :kind, :slot, :value, :source, :manufacturer)
    Ambiguity = Data.define(:span, :candidates)

    Result = Data.define(
      :valid, :move, :observations, :pending_resolution, :clarification_target,
      :identities, :ambiguities, :field_rejections, :catalog_disagreements, :invalid_reason,
      :correction
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

    # Same rejections coerce_tool applied before rewriting slot_hint.
    # It does not drop spans, clear pending_resolution, or run build.
    def self.structural_failure(raw)
      return "not_a_hash" unless raw.is_a?(Hash)

      data = raw.deep_stringify_keys
      return "extra_keys" if (data.keys - ROOT_KEYS).any?
      return "invalid_move" unless MOVES.include?(data["move"])
      return "invalid_assertions" unless data["assertions"].is_a?(Array)
      return "invalid_observations" unless data["observations"].is_a?(Array)
      return "too_many_assertions" if data["assertions"].size > MAX_ASSERTIONS
      return "too_many_observations" if data["observations"].size > ActiveEpisode::MAX_OBSERVATIONS
      unless data["pending_resolution"].nil? || RESOLUTIONS.include?(data["pending_resolution"])
        return "invalid_pending_resolution"
      end

      clarification = clarification_failure(data)
      return clarification if clarification
      return "malformed_assertion" unless data["assertions"].all? { |item| assertion_shape?(item) }
      return "invalid_observation" unless data["observations"].all? { |item| item.is_a?(String) }
      return "over_bytes" if JSON.generate(data).bytesize > MAX_TOOL_BYTES

      nil
    end

    def self.clarification_failure(data)
      return "missing_clarification_target" unless data.key?("clarification_target")

      target = data["clarification_target"]
      return "invalid_clarification_target" unless target.nil? || CLARIFICATION_TARGETS.include?(target)
      return "unclear_without_target" if data["move"] == "unclear" && target.nil?
      return "clarification_target_not_null" if data["move"] != "unclear" && !target.nil?

      nil
    end

    def self.assertion_shape?(item)
      return false unless item.is_a?(Hash)

      keys = item.keys.map(&:to_s)
      return false if (keys - ASSERTION_KEYS).any?
      return false unless item["span"].is_a?(String) || item[:span].is_a?(String)
      return false unless ACTS.include?(item["act"] || item[:act])

      true
    end

    # Literal substring check used by the product and by the experiment.
    # The product drops a failed span. The experiment rejects the payload.
    def self.literal_fragment?(span, turn)
      candidate = normalize_span_text(span).sub(/\A\p{P}+/u, "").sub(/\p{P}+\z/u, "")
      return false if candidate.empty?

      normalize_span_text(turn).include?(candidate)
    end

    def self.normalize_span_text(value)
      value.to_s.unicode_normalize(:nfc).downcase.gsub(/[[:space:]]+/, " ").strip
    end

    def self.over_length?(data)
      data["assertions"].any? { |item| item["span"].length > ActiveEpisode::MAX_VALUE_CHARS } ||
        data["observations"].any? { |item| item.length > ActiveEpisode::MAX_OBSERVATION_CHARS }
    end

    def initialize(raw:, turn:, episode:, catalog:, viewer_account:)
      @raw = raw
      @turn = TurnText.truncate(turn)
      @episode = episode || ActiveEpisode.new
      @catalog = catalog
      @viewer_account = viewer_account
      @field_rejections = []
      @catalog_disagreements = []
      @adjustments = []
    end

    def build
      data = coerce_tool(@raw)
      return invalid("invalid_schema") if data.nil?
      return invalid("over_length") if over_length?(data)

      assertions = literal_assertions(data["assertions"])
      observations = literal_observations(data["observations"])
      @correction = ObservationCorrection.resolve(
        turn: @turn, observations: observations, assertions: assertions
      )
      identities, ambiguities = resolve_assertions(assertions, observations)
      move = data["move"]
      resolution = data["pending_resolution"]
      move, resolution, identities, observations, ambiguities, target = recover_stated_correction(
        move, resolution, identities, observations, ambiguities, data["clarification_target"]
      )
      move, resolution, identities, observations, ambiguities, target = adjust_move(
        move, resolution, identities, observations, ambiguities, target
      )
      if move == "meta" && meta_incompatible?(@turn)
        note_rule("reject_meta", "meta", "meta_incompatible", { "from" => "meta", "to" => "fallback" })
        return invalid("meta_incompatible", original_move: "meta")
      end
      resolution = nil unless move == "answer_pending"
      identities = apply_structured_slots(move, resolution, identities)

      result = Result.new(
        valid: true,
        move: move,
        observations: observations,
        pending_resolution: resolution,
        clarification_target: target,
        identities: identities,
        ambiguities: ambiguities,
        field_rejections: @field_rejections,
        catalog_disagreements: @catalog_disagreements,
        invalid_reason: nil,
        correction: @correction || ObservationCorrection.none
      )
      record_perception(result)
      result
    end

    private

    def coerce_tool(raw)
      return nil if self.class.structural_failure(raw)

      data = raw.deep_stringify_keys
      data["assertions"] = data["assertions"].map { |item| normalize_assertion(item.deep_stringify_keys) }
      data
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
      self.class.over_length?(data)
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
      self.class.literal_fragment?(span, @turn)
    end

    def normalize_span(value)
      self.class.normalize_span_text(value)
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
        compound = compound_identities(item)
        if compound
          identities.concat(compound)
          next
        end

        found = draft[index] || remainder_identity(item, context)
        if found.is_a?(Ambiguity)
          ambiguities << found
        else
          identities << found
        end
      end
      [ identities, ambiguities ]
    end

    # The span stays an identifier. A matching brand and designator also
    # record the manufacturer the way a lone brand does. Negating that span
    # drops this manufacturer only when it is the one stored.
    def compound_identities(item)
      return nil unless %w[assert negate].include?(item["act"])

      match = lookup_compound(item["span"])
      return nil if match.nil?

      if item["act"] == "negate"
        note_rule("compound_brand", item["span"], "negated_same_entry", { "brand" => match.brand })
        rows = [ identifier_negation(item["span"]) ]
        rows.unshift(manufacturer_negation(item["span"], match.brand)) if stored_brand?(match.brand)
        return rows
      end

      disagree(item["span"], item["slot_hint"], "manufacturer")
      note_rule("compound_brand", item["span"], "same_entry", { "brand" => match.brand })
      [
        fact(item["span"], "assert", "manufacturer", match.brand, declared_source(item["span"], match.brand), match.brand),
        identifier(item["span"], "assert")
      ]
    end

    def manufacturer_negation(span, brand)
      Identity.new(
        span: span, act: "negate", kind: "negate", slot: "manufacturer",
        value: brand, source: nil, manufacturer: brand
      )
    end

    def identifier_negation(span)
      Identity.new(
        span: span, act: "negate", kind: "negate", slot: "identifier",
        value: span, source: nil, manufacturer: nil
      )
    end

    def stored_brand?(brand)
      fact = @episode.respond_to?(:fact) ? @episode.fact("manufacturer") : nil
      return false unless fact.is_a?(Hash) && fact["value"].present?

      FollowupQueryRewriter.normalize_label(fact["value"]) == FollowupQueryRewriter.normalize_label(brand)
    end

    def lookup_compound(span)
      return nil if @viewer_account.nil? || @catalog.nil? || !@catalog.respond_to?(:resolve_compound_brand)

      @catalog.resolve_compound_brand(span, viewer_account: @viewer_account)
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
        return fact(
          item["span"], item["act"], slot, designator.value,
          declared_source(item["span"], designator.value), designator.manufacturer
        )
      end

      identifier(item["span"], item["act"])
    end

    def remainder_identity(item, context)
      return negate_identity(item) if item["act"] == "negate"

      brand = lookup_brand(item["span"])
      if brand&.status == :exact
        disagree(item["span"], item["slot_hint"], "manufacturer")
        return fact(
          item["span"], item["act"], "manufacturer", brand.manufacturer,
          declared_source(item["span"], brand.manufacturer), brand.manufacturer
        )
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

    # The turn already names the rejected value and its replacement. Keep the
    # other identities and the other checks from that same turn. A model
    # reading of correction_target would ask which datum changed and drop both.
    # The slot hint does not decide this. The clause must name the value, and
    # the catalog value must be that same label. A question or a hedge stays
    # catalog. A manufacturer the catalog adds is not this method.
    def declared_source(span, value)
      return "catalog" unless declared_identity?(span) && catalog_normalizes?(span, value)

      note_rule("identity_source", span, "catalog_normalized", { "value" => value })
      "user"
    end

    def declared_identity?(span)
      clause = identity_clause(span)
      return false if clause.blank?

      folded = clause.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "")
      return false if folded.match?(/[¿?]/)
      return false if folded.match?(IDENTITY_HEDGE)

      true
    end

    def identity_clause(span)
      needle = normalize_span(span)
      return "" if needle.blank?

      @turn.to_s.split(/[.;]\s+|\n+/).find { |clause| normalize_span(clause).include?(needle) }.to_s
    end

    def catalog_normalizes?(span, value)
      left = normalize_span(span)
      right = normalize_span(value)
      return false if left.blank? || right.blank?
      return true if left == right
      return false if right.match?(/\d/)

      left.match?(/(?<![[:alnum:]])#{Regexp.escape(right)}(?![[:alnum:]])/)
    end

    def recover_stated_correction(move, resolution, identities, observations, ambiguities, target)
      codes = explicit_fault_codes
      if codes
        @correction = ObservationCorrection.none
        old_code, new_code = codes
        identities = merged_fault_identities(identities, old_code, new_code)
        observations = merged_fault_observations(observations, old_code)
        note_rule(
          "recover_stated_correction", "fault_code", "explicit_fault_codes",
          { "rejected" => old_code, "asserted" => new_code }
        )
        return [ "correct", nil, identities, observations, ambiguities, nil ]
      end

      phrase = keep_stated_correction
      if phrase && %w[unclear correct report follow_up].include?(move)
        # The interpreter may return the entire correction as an observation.
        # Its rejected tail must not make the durable replacement look redundant.
        current = observations.reject { |text|
          contained_phrase?(
            FollowupQueryRewriter.normalize_label(phrase),
            FollowupQueryRewriter.normalize_label(text)
          ) && correction_tail?(text)
        }
        merged = merge_phrase(current, phrase)
        kept = identities.reject { |item| observation_fragment?(item, merged) }
        note_rule("recover_stated_correction", phrase, "observation_correction")
        return [ "correct", nil, kept, merged, ambiguities, nil ]
      end

      @correction = ObservationCorrection.none unless @correction&.active?
      [ move, resolution, identities, observations, ambiguities, target ]
    end

    def keep_stated_correction
      return nil unless @correction&.active?

      phrase = @correction.asserted.find { |text| literal_span?(text) && symptom_observation?(text) }
      if phrase
        @correction = ObservationCorrection::Result.new(asserted: [ phrase ], retracted: @correction.retracted)
      else
        @correction = ObservationCorrection.none
      end
      phrase
    end

    def merged_fault_identities(identities, old_code, new_code)
      kept = identities.reject { |item| asserts_fault?(item, old_code) }
      unless kept.any? { |item| item.kind == "negate" && item.slot == "fault_code" && fault_label(item) == old_code }
        kept = [
          Identity.new(
            span: old_code, act: "negate", kind: "negate", slot: "fault_code",
            value: old_code, source: nil, manufacturer: nil
          )
        ] + kept
      end
      unless kept.any? { |item| item.act == "assert" && item.slot == "fault_code" && fault_label(item) == new_code }
        kept << fact(new_code, "assert", "fault_code", new_code, "user", nil)
      end
      kept
    end

    def merged_fault_observations(observations, old_code)
      kept = observations.reject { |text|
        stale = SlotRejection.code_statement?(FollowupQueryRewriter.normalize_label(text), old_code)
        note_rule("merged_fault_observations", text, "stale_fault_observation") if stale
        stale
      }
      symptom_sentences_outside_correction(old_code).each do |phrase|
        kept = merge_phrase(kept, phrase)
      end
      kept
    end

    def symptom_sentences_outside_correction(old_code)
      @turn.split(/(?<=[.!?])\s+/).filter_map do |sentence|
        phrase = sentence.to_s.squish.sub(/[.!?]+\z/, "")
        next if phrase.blank?

        normalized = FollowupQueryRewriter.normalize_label(phrase)
        next if normalized.match?(/\bcodigo\s+\d+\b/) || normalized.match?(/\bno\s+#{Regexp.escape(old_code)}\b/)
        next unless symptom_observation?(phrase) && literal_span?(phrase)
        next if ObservationText.continuity_echo?(phrase)

        phrase
      end
    end

    # A shorter phrase inside a longer one is the same fact only when the
    # longer one is kept. The extra qualifier, negation, condition, or result
    # stays. The shorter copy is not stored beside it.
    def merge_phrase(observations, phrase)
      label = FollowupQueryRewriter.normalize_label(phrase)
      return observations if label.blank?

      rows = observations.dup
      rows << phrase unless rows.any? { |text| FollowupQueryRewriter.normalize_label(text) == label }
      drop_contained_phrases(rows)
    end

    def drop_contained_phrases(rows)
      seen = []
      rows.reject { |text|
        inner = FollowupQueryRewriter.normalize_label(text)
        next true if inner.blank? || seen.include?(inner)

        contained = rows.any? { |other| contained_phrase?(inner, FollowupQueryRewriter.normalize_label(other)) }
        note_rule("drop_contained_phrases", text, "contained_phrase") if contained
        seen << inner unless contained
        contained
      }
    end

    def contained_phrase?(inner, outer)
      return false if inner.blank? || outer.blank? || inner == outer

      outer.match?(/(?<![[:alnum:]])#{Regexp.escape(inner)}(?![[:alnum:]])/)
    end

    def correction_tail?(text)
      ObservationCorrection.tail?(text)
    end

    def asserts_fault?(item, code)
      item.act == "assert" && item.slot == "fault_code" && fault_label(item) == code
    end

    def fault_label(item)
      FollowupQueryRewriter.normalize_label(item.value.presence || item.span)
    end

    def explicit_fault_codes
      normalized = FollowupQueryRewriter.normalize_label(@turn)
      match = normalized.match(/\bcodigo\s+(\d+)\b\W{0,12}\bno\s+(\d+)\b/)
      old_code, new_code = if match
        [ match[2], match[1] ]
      else
        reverse = normalized.match(/\bno\s+(?:es\s+)?codigo\s+(\d+)\b\W{0,24}\bcodigo\s+(\d+)\b/)
        reverse ? [ reverse[1], reverse[2] ] : nil
      end
      return nil if old_code.blank? || new_code.blank? || old_code == new_code
      return nil unless literal_span?(old_code) && literal_span?(new_code)

      [ old_code, new_code ]
    end

    def adjust_move(move, resolution, identities, observations, ambiguities, target)
      if move == "meta" && technical_recap?(@turn)
        note_rule("adjust_move", "meta", "technical_recap", { "to" => "follow_up" })
        move = "follow_up"
      end
      if move == "answer_pending" && !pending_answer?(resolution, identities)
        note_rule("adjust_move", move, "pending_answer_incomplete")
        move = identities.any? || observations.any? || ambiguities.any? ? "report" : "follow_up"
        resolution = nil
      elsif move == "correct" && identities.none? { |item| item.kind == "negate" && item.slot.present? }
        unless observation_correction?(identities, observations)
          note_rule("adjust_move", "move", "correct_without_slot_negation", { "from" => move, "to" => "unclear" })
          note_rule("adjust_move", identities.map(&:span).join(", "), "correct_without_slot_negation") if identities.any?
          note_rule("adjust_move", observations.join(" | "), "correct_without_slot_negation") if observations.any?
          move = "unclear"
          target = "correction_target"
          resolution = nil
          identities = []
          observations = []
        end
      elsif move == "new_work" && !self.class.technical_payload?(identities, observations, ambiguities) && prior_context? && !work_relation_pending?
        note_rule("adjust_move", move, "new_work_without_technical_payload")
        move = "follow_up"
      end
      target = nil unless move == "unclear"
      [ move, resolution, identities, observations, ambiguities, target ]
    end

    # An observation correction has no slot to negate. A fragment of the
    # recovered phrase is not equipment identity and does not block that
    # correction. Another identifier, and a catalog fact from the same turn,
    # stay. Sharing words with the observation does not make that fact a
    # fragment. A slotted negate, or a negate paired with an assert, still
    # needs the stored value and its replacement.
    def observation_correction?(identities, observations)
      return false if observations.empty?
      return false if identities.any? { |item| item.kind == "negate" && item.slot.present? }

      explicit = @correction&.active?
      blocking = identities.select { |item|
        item.act == "assert" && %w[fact identifier].include?(item.kind) &&
          !observation_fragment?(item, observations)
      }
      return false if blocking.any? && !explicit
      return false if identities.any? { |item| item.act == "negate" } &&
        identities.any? { |item| item.act == "assert" && !observation_fragment?(item, observations) }

      true
    end

    # Only an identifier that is the recovered observation, or a piece of it.
    # A catalog fact is equipment identity even when the observation names it.
    def observation_fragment?(item, observations)
      return false unless item.act == "assert" && item.kind == "identifier"

      label = FollowupQueryRewriter.normalize_label(item.value.presence || item.span)
      return false if label.blank?

      observations.any? { |text|
        normalized = FollowupQueryRewriter.normalize_label(text)
        normalized == label || contained_phrase?(label, normalized)
      }
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

    # A summary of the open job, or the next observation, is the technical
    # route. A greeting, a question about what Danebo needs, or an offer to
    # send evidence stays meta. This is not a list of fixture sentences.
    def technical_recap?(text)
      normalized = FollowupQueryRewriter.normalize_label(text)
      return false if normalized.blank?
      return false if normalized.match?(/\bnecesita/)
      return false if normalized.split.all? { |word| word.match?(RoutePolicy::GREETING_TOKEN) }
      return false if evidence_offer?(normalized)

      normalized.match?(/\bresum/) ||
        (normalized.match?(/\bobservacion/) && normalized.match?(/\b(?:sigue|siguiente)/))
    end

    # meta may not drop a searchable turn. A greeting, an acknowledgement,
    # a request for what Danebo needs, a lone evidence offer, and a question
    # about using Danebo or selecting a manual stay meta. Any other meta is
    # incompatible: the turn is searched and is not stored as a fact.
    # Document focus is not an input.
    def meta_incompatible?(text)
      return false unless RoutePolicy.searchable_symptom?(text)

      !administrative_meta?(FollowupQueryRewriter.normalize_label(text))
    end

    def administrative_meta?(normalized)
      courtesy_greeting?(normalized) || assistant_request?(normalized) ||
        evidence_offer?(normalized) || product_help?(normalized)
    end

    def courtesy_greeting?(normalized)
      tokens = normalized.to_s.split
      return false if tokens.empty? || technical_marker?(normalized)

      tokens.all? { |word| word.match?(RoutePolicy::GREETING_TOKEN) || word.match?(COURTESY_TOKEN) }
    end

    def assistant_request?(normalized)
      return false if technical_marker?(normalized)

      normalized.match?(/\bnecesitas\b/)
    end

    def product_help?(normalized)
      return false if technical_marker?(normalized)
      return true if normalized.match?(/\bdanebo\b/) && (
        normalized.match?(PRODUCT_OPERATION) || normalized.match?(/\b(?:que es|para que)\b/)
      )

      normalized.match?(MANUAL_SELECTION) && normalized.match?(PRODUCT_DOCUMENT)
    end

    def technical_marker?(normalized)
      normalized.match?(TECHNICAL_MARKER)
    end

    def evidence_offer?(normalized)
      return false if technical_marker?(normalized)

      tokens = normalized.to_s.split
      return false if tokens.empty? || tokens.none? { |word| word.match?(MEDIA_TOKEN) }

      tokens.all? { |word| word.match?(LONE_OFFER_TOKEN) }
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
        note_rule("apply_structured_slots", item.span, "typed_pending_value", { "slot" => slot })
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
        note_rule("apply_structured_slots", item.span, "typed_correction", { "slot" => negated.slot })
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
      note_rule("reject_field", field, reason)
    end

    def invalid(reason, original_move: nil)
      result = Result.new(
        valid: false, move: nil, observations: [], pending_resolution: nil, clarification_target: nil,
        identities: [], ambiguities: [], field_rejections: @field_rejections,
        catalog_disagreements: [], invalid_reason: reason,
        correction: ObservationCorrection.none
      )
      record_perception(result, original_move: original_move)
      result
    end

    def note_rule(rule, datum, reason, detail = nil)
      return unless ValidationCapture.active?

      row = { "rule" => rule, "datum" => datum.to_s, "reason" => reason.to_s }
      row["detail"] = detail if detail.present?
      @adjustments << row
    end

    def record_perception(result, original_move: nil)
      return unless ValidationCapture.active?

      payload = {
        "stage" => "perception",
        "result" => result.valid ? "valid" : "invalid",
        "links" => "interpreter_raw",
        "valid" => result.valid,
        "move" => result.move,
        "invalid_reason" => result.invalid_reason,
        "clarification_target" => result.clarification_target,
        "identities" => result.identities.map { |item| compact_identity(item) },
        "observations" => result.observations,
        "adjustments" => @adjustments,
        "field_rejections" => @field_rejections
      }
      payload["original_move"] = original_move if original_move.present?
      ValidationCapture.record("perception_applied", payload)
    end

    def compact_identity(item)
      {
        "span" => item.span,
        "act" => item.act,
        "kind" => item.kind,
        "slot" => item.slot,
        "value" => item.value
      }
    end
  end
end
