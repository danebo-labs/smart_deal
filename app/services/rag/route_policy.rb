# frozen_string_literal: true

module Rag
  # What to do with a validated perception, given the episode and the fresh
  # Document Focus. It does not call a model and it does not write state.
  class RoutePolicy
    Decision = Data.define(
      :decision, :retrieval_query, :clarification, :pending_subject,
      :outside_discovery, :owns_query, :bare_identifier, :ask_when, :mutations,
      :dialogue_function, :context_carry, :focus_uris, :focus_document_ids,
      :pending_question, :fallback
    ) do
      def clarify_first?
        decision == "clarify_first"
      end

      def search_and_clarify?
        decision == "search_and_clarify"
      end

      def best_effort?
        decision == "best_effort"
      end

      def meta?
        decision == "meta"
      end

      def performs_retrieval?
        %w[ready search_and_clarify best_effort].include?(decision)
      end
    end

    def self.call(previous:, perception:, focus_count:, focus_document_ids: [], focus_uris: [], locale: :es, relevant_photo: nil)
      new(
        previous: previous, perception: perception, focus_count: focus_count,
        focus_document_ids: focus_document_ids, focus_uris: focus_uris, locale: locale,
        relevant_photo: relevant_photo
      ).call
    end

    def self.fallback(episode:, turn:, focus_count:, focus_document_ids:, focus_uris:, catalog:, viewer_account:, locale: :es)
      new(
        previous: episode, perception: nil, focus_count: focus_count,
        focus_document_ids: focus_document_ids, focus_uris: focus_uris, locale: locale
      ).fallback(turn, catalog, viewer_account)
    end

    def initialize(previous:, perception:, focus_count:, focus_document_ids:, focus_uris:, locale:, relevant_photo: nil)
      @previous = previous || ActiveEpisode.new
      @perception = perception
      @focus_count = focus_count.to_i
      @focus_document_ids = Array(focus_document_ids)
      @focus_uris = Array(focus_uris)
      @locale = locale.to_sym
      @relevant_photo = relevant_photo
    end

    def call
      previous = @perception.move == "new_work" ? ActiveEpisode.new : @previous
      if @perception.move == "meta"
        return finish("meta", outside_discovery: false, owns_query: false, clarification: I18n.t("rag.meta_continue", locale: @locale), capture: true, condition: "move_meta")
      end
      if @perception.move == "unclear" && @perception.clarification_target.present?
        target = @perception.clarification_target
        return finish(
          "clarify_first",
          outside_discovery: false,
          owns_query: false,
          clarification: I18n.t("rag.clarify_#{target}", locale: @locale),
          pending_subject: target,
          pending_question: conversational_pending(target),
          capture: true,
          condition: "unclear_with_target"
        )
      end
      if thin_new_work?
        return finish(
          "clarify_first",
          outside_discovery: false,
          owns_query: false,
          clarification: I18n.t("rag.clarify_new_work", locale: @locale),
          capture: true,
          condition: "thin_new_work"
        )
      end
      if clarify_first?(previous)
        return finish(
          "clarify_first",
          outside_discovery: false,
          owns_query: false,
          clarification: clarify_text,
          pending_subject: "controller",
          ask_when: :instead,
          pending_question: pending_with_carry("controller"),
          capture: true,
          condition: "clarify_first"
        )
      end
      if best_effort?
        return finish("best_effort", outside_discovery: true, owns_query: true, capture: true, condition: "best_effort")
      end
      ambiguous = @perception.ambiguities.first
      if ambiguous
        return finish(
          "search_and_clarify",
          outside_discovery: true,
          owns_query: true,
          clarification: I18n.t("rag.clarify_ambiguous_designator", token: ambiguous.candidates.join(" / "), locale: @locale),
          pending_subject: "controller",
          ask_when: :always,
          pending_question: { "type" => "controller" },
          capture: true,
          condition: "ambiguous_designator"
        )
      end
      if focus_mention?
        token = short_mention.span
        return finish(
          "search_and_clarify",
          outside_discovery: false,
          owns_query: true,
          clarification: I18n.t("rag.clarify_identifier_focus", token: token, locale: @locale),
          pending_subject: "controller",
          ask_when: :absence,
          bare_identifier: token,
          pending_question: { "type" => "controller" },
          capture: true,
          condition: "focus_mention"
        )
      end

      finish("ready", outside_discovery: true, owns_query: true, capture: true, condition: "ready")
    end

    def fallback(turn, catalog, viewer_account)
      repeated = conversational_fallback
      return repeated if repeated

      if thin?(@previous) && @focus_count.zero?
        if searchable_symptom?(turn)
          query = fallback_query(turn, catalog, viewer_account)
          return finish(
            "ready",
            outside_discovery: false,
            owns_query: query.present?,
            retrieval_query: query,
            fallback: true,
            capture: true,
            condition: "fallback_searchable_symptom"
          )
        end

        return finish(
          "clarify_first",
          outside_discovery: false,
          owns_query: false,
          clarification: I18n.t("rag.clarify_controller", locale: @locale),
          pending_subject: "controller",
          ask_when: :instead,
          pending_question: { "type" => "controller" },
          fallback: true,
          capture: true,
          condition: "fallback_thin_clarify"
        )
      end

      query = fallback_query(turn, catalog, viewer_account)
      pending = @previous.pending_question || pending_from_fact
      finish(
        "ready",
        outside_discovery: false,
        owns_query: query.present?,
        retrieval_query: query,
        clarification: pending ? I18n.t("rag.clarify_controller", locale: @locale) : nil,
        pending_subject: pending && pending["type"],
        ask_when: pending ? :always : nil,
        pending_question: pending,
        fallback: true,
        capture: true,
        condition: "fallback_ready"
      )
    end

    private

    def thin_new_work?
      @perception.move == "new_work" && !@perception.technical_payload?
    end

    # A failed interpretation does not guess the reply. The open conversational
    # question is repeated and the pending, including its carry, stays put.
    def conversational_fallback
      question = @previous.pending_question
      type = question.is_a?(Hash) ? question["type"].to_s : ""
      return nil unless PendingQuestion::CONVERSATIONAL_TYPES.include?(type)

      finish(
        "clarify_first",
        outside_discovery: false,
        owns_query: false,
        clarification: I18n.t("rag.clarify_#{type}", locale: @locale),
        pending_subject: type,
        pending_question: question,
        fallback: true,
        capture: true,
        condition: "fallback_conversational_pending"
      )
    end

    def conversational_pending(target)
      question = { "type" => target }
      carry = conversational_carry
      question["carry"] = carry if carry.any?
      question
    end

    def conversational_carry
      existing = PendingQuestion.sanitize_carry(@previous.pending_question&.dig("carry"))
      return existing if existing.any?

      carry_spans
    end

    def clarify_first?(previous)
      return false if @focus_count.positive?
      return false if %w[answer_pending correct new_work unclear].include?(@perception.move)
      return false if @perception.ambiguities.any?
      return false unless thin?(previous)
      return false if @perception.observations.any?
      return false if @perception.facts.any?
      return false if @perception.identities.any? { |item| item.act == "assert" && item.kind == "identifier" }

      true
    end

    def thin?(episode)
      return true if episode.nil? || episode.blank?

      !known_identity?(episode) && episode.fact("fault_code").nil? &&
        episode.observations.empty? && episode.goal.blank? && !photo_counts?(episode)
    end

    def photo_counts?(episode)
      return false if episode.active_photo.blank?
      return true if @relevant_photo.nil?

      @relevant_photo == true
    end

    def known_identity?(episode)
      %w[manufacturer model controller].any? { |key| known_fact?(episode, key) }
    end

    def known_fact?(episode, key)
      fact = episode.fact(key)
      fact.is_a?(Hash) && fact["status"] == "known" && fact["value"].present?
    end

    def best_effort?
      return false unless @perception.move == "answer_pending"

      resolution = @perception.pending_resolution
      return true if %w[unknown seek].include?(resolution)

      slot = pending_slot(@previous)
      fact = slot && @previous.fact(slot)
      fact.is_a?(Hash) && fact["status"] == "unknown_confirmed"
    end

    GREETING_TOKEN = /\A(?:hola|buenas|buen|dia|dias|gracias|ok|vale|hello|hi|hey|thanks)\z/i

    def searchable_symptom?(turn)
      tokens = turn.to_s.scan(/[\p{L}\d][\p{L}\d-]*/)
      return false if tokens.size < 2

      tokens.any? { |token| !token.match?(GREETING_TOKEN) }
    end

    def focus_mention?
      return false unless @focus_count.positive?
      return false if @perception.facts.any?
      return false if @perception.identifiers.any?

      mention = short_mention
      mention && @perception.mentions.one? && @perception.identities.all? { |item| item.kind == "mention" || item.kind == "negate" }
    end

    def short_mention
      @perception.mentions.find { |item| item.span.match?(/\A[\p{L}\d]{2,4}\z/) }
    end

    def clarify_text
      token = carry_spans.first
      if token.present?
        I18n.t("rag.clarify_identifier", token: token, locale: @locale)
      else
        I18n.t("rag.clarify_controller", locale: @locale)
      end
    end

    def carry_spans
      @perception.identities.filter_map { |item|
        next unless %w[mention identifier].include?(item.kind)
        next if item.span.length > ActiveEpisode::MAX_VALUE_CHARS

        item.span
      }.uniq.first(PendingQuestion::MAX_CARRY)
    end

    def pending_with_carry(type)
      question = { "type" => type }
      spans = carry_spans
      question["carry"] = spans if spans.any?
      question
    end

    def pending_slot(episode)
      type = episode.pending_question&.dig("type")
      return type if ActiveEpisode::PENDING_SUBJECTS.include?(type.to_s)

      subject = episode.pending_fact&.dig("subject")
      subject if ActiveEpisode::PENDING_SUBJECTS.include?(subject.to_s)
    end

    def pending_from_fact
      slot = pending_slot(@previous)
      return nil if slot.blank?

      question = { "type" => slot }
      carry = @previous.pending_question&.dig("carry")
      question["carry"] = carry if carry.is_a?(Array) && carry.any?
      question
    end

    def fallback_query(turn, catalog, viewer_account)
      state_query = QueryComposer.call(
        state: @previous,
        turn: turn,
        perception: fallback_perception,
        decision: finish("ready", outside_discovery: false, owns_query: true)
      )
      extra = catalog_tokens(turn, catalog, viewer_account)
      [ state_query, extra ].compact_blank.uniq { |item| FollowupQueryRewriter.normalize_label(item) }.join(" ").truncate(FollowupQueryRewriter::MAX_COMPOSED_CHARS)
    end

    def fallback_perception
      TurnPerception::Result.new(
        valid: true, move: "report", observations: [], pending_resolution: nil, clarification_target: nil,
        identities: [], ambiguities: [], field_rejections: [], catalog_disagreements: [], invalid_reason: nil
      )
    end

    def catalog_tokens(turn, catalog, viewer_account)
      return nil if catalog.nil? || viewer_account.nil?

      tokens = turn.to_s.scan(/[\p{L}\d][\p{L}\d-]{1,29}/)
      found = tokens.filter_map { |token|
        designator = catalog.resolve_designator(token, viewer_account: viewer_account)
        if (designator.status == :exact || designator.status == :prefix) && designator.type.present?
          next designator.value
        end

        brand = catalog.resolve_brand(token, viewer_account: viewer_account)
        brand.manufacturer if brand.status == :exact
      }
      found.presence&.join(" ")
    end

    def finish(name, outside_discovery:, owns_query:, clarification: nil, pending_subject: nil, ask_when: nil, pending_question: nil, retrieval_query: nil, bare_identifier: nil, fallback: false, capture: false, condition: nil)
      decision = Decision.new(
        decision: name,
        retrieval_query: retrieval_query,
        clarification: clarification,
        pending_subject: pending_subject,
        outside_discovery: outside_discovery,
        owns_query: owns_query,
        bare_identifier: bare_identifier,
        ask_when: ask_when,
        mutations: [],
        dialogue_function: @perception&.move,
        context_carry: false,
        focus_uris: @focus_uris,
        focus_document_ids: @focus_document_ids,
        pending_question: pending_question,
        fallback: fallback
      )
      record_route(decision, condition) if capture
      decision
    end

    def record_route(decision, condition)
      return unless ValidationCapture.active?

      payload = {
        "route" => decision.decision,
        "condition" => condition.to_s,
        "fallback" => decision.fallback,
        "retrieval" => decision.performs_retrieval?
      }
      payload["episode_id"] = @previous.episode_id if @previous.episode_id.present?
      ValidationCapture.record("route_decision", payload)
    end
  end
end
