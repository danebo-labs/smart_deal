# frozen_string_literal: true

module Rag
  # One classification of a technician turn against the active episode.
  # Rules run in Anexo B order. The first match wins. Nothing here is persisted.
  class ActiveEpisodeTurn
    Result = Data.define(:decision, :reason, :state, :composed, :fields_changed)

    MANUFACTURERS = [
      "fuji yida", "thyssenkrupp", "thyssen", "tke", "otis", "kone", "schindler",
      "mitsubishi", "orona", "hyundai", "fermator", "blt", "elemont"
    ].freeze

    DESIGNATOR_RE = /(?<![\p{L}\d])[\p{L}\d][\p{L}\d\-]{1,29}(?![\p{L}\d])/
    RESET_RE = /\b(nueva falla|otra falla|otro equipo|otro ascensor|otra maquina|cambio de equipo|new fault|another (unit|elevator|lift))\b/
    CORRECTION_RE = /\b(no es|no era|me equivoque|en realidad|corrijo|perdon es|not a|actually)\b/
    SUBJECT_RE = /\b(revisando|estoy en|estoy con|tengo|equipo|ascensor|elevador|es un|es una|checking)\b/
    FOLLOWUP_RE = /\b(la misma|el mismo|lo mismo|esa|ese|eso|esta|este|esto|ahi|same|that|this|it)\b/
    FOLLOWUP_START_RE = /\A(y|and|pero|sigue|ahora|tambien|still)\b/
    UNKNOWN_RE = /\bno (lo )?(se|sabemos|tengo)\b/
    BRAND_WORD_RE = /\b(marca|fabricante|brand|manufacturer)\b/
    MODEL_WORD_RE = /\b(modelo|model)\b/
    MODEL_VALUE_RE = /\b(?:modelo|model)\s*(?:es\s*)?:?\s*([A-Za-z0-9][A-Za-z0-9\-]{1,20})\b/
    # Explicit "modelo es X" is already a strong signal. Mixed-case names such
    # as MonoSpace fail KbDocumentResolver.specific_token? (no digit, not
    # all-caps). That gate stays for loose designators; this list only rejects
    # function words the model regex can still capture.
    MODEL_DECLARATION_STOPWORDS = %w[
      no si un una el la los las es de del que como para por con
      este esta eso esa the and not for with this that what how
    ].freeze
    ABSENT_CODE_RE = /\bno (muestra|marca|aparece|hay|tiene)\b.*\bcodigo\b|\bsin codigo\b|\bningun codigo\b|\bno code\b/
    KNOWN_CODE_RE = /\b(codigo|error|code)\s+(n\s+)?([a-z]?\d{1,4}[a-z]?)\b/
    MEASUREMENT_RE = /\b(lo medi|yo medi|medimos|medicion|medi)\b/
    DEICTIC_RE = /\b(esa|ese|eso|esta|este|esto|that|this)\s+(placa|foto|imagen|plate|photo)\b/
    NO_PLATE_RE = /\bno se ve\b|\bno tiene placa\b/
    CODE_WORD_RE = /\b(codigo|code|error)\b/
    FILLER = %w[es un una no si].freeze
    RESOLVED = %w[known unknown_confirmed absent_confirmed].freeze
    FROM_STATE = Object.new

    def self.call(state:, text:, role: "user", now: Time.current, selection_turn: false, pending_fact: FROM_STATE,
                  correlation_id: nil, channel: "web", enabled: nil, shared: nil, prior_user_turns: [],
                  analysis: nil, account: nil)
      new(
        state: state,
        text: text.to_s,
        role: role.to_s,
        now: now,
        selection_turn: selection_turn,
        pending_fact: pending_fact,
        correlation_id: correlation_id,
        channel: channel.to_s,
        enabled: enabled.nil? ? FieldCompanionEpisodeFlag.enabled? : enabled,
        shared: shared.nil? ? SharedSession::ENABLED : shared,
        prior_user_turns: prior_user_turns,
        analysis: analysis,
        account: account
      ).call
    end

    # pending_fact from the assistant reply, using the full text before truncation.
    def self.apply_assistant(state:, text:, now: Time.current, correlation_id: nil, pending_question: nil)
      episode = coerce_episode(state, now)
      return skipped_result(episode) if episode.blank?

      before = episode.fork
      reason = write_pending!(episode, text.to_s, correlation_id: correlation_id, pending_question: pending_question)
      episode.touch!(now)
      Result.new(
        decision: :assistant,
        reason: reason,
        state: episode.to_h,
        composed: nil,
        fields_changed: changed_fields(before, episode)
      )
    end

    def self.coerce_episode(state, now)
      case state
      when ActiveEpisode then state
      else ActiveEpisode.parse(state, now: now)
      end
    end

    def self.skipped_result(episode)
      Result.new(decision: :skipped, reason: episode.reason, state: episode.to_h, composed: nil, fields_changed: [])
    end

    def self.write_pending!(episode, text, correlation_id:, pending_question: nil)
      episode.clear_pending!
      question = PendingQuestion.coerce(pending_question)
      if question
        episode.pending_question = question
        if PendingQuestion::FACT_TYPES.include?(question["type"])
          episode.pending_fact = { "subject" => question["type"], "correlation_id" => correlation_id.to_s }
        end
        return nil
      end

      subjects = text.scan(/[^?]+\?/).filter_map { |sentence| pending_subject(FollowupQueryRewriter.normalize_label(sentence)) }
      return nil unless subjects.size == 1

      subject = subjects.first
      if RESOLVED.include?(episode.fact(subject)&.dig("status"))
        return "assistant_repeated_question"
      end

      episode.pending_fact = { "subject" => subject, "correlation_id" => correlation_id.to_s }
      nil
    end

    def self.pending_subject(normalized)
      return "manufacturer" if BRAND_WORD_RE.match?(normalized)
      return "model" if MODEL_WORD_RE.match?(normalized)
      return "fault_code" if CODE_WORD_RE.match?(normalized)

      nil
    end

    def self.changed_fields(before, after)
      left = before.to_h
      right = after.to_h
      changed = []
      changed << "episode_id" if left["episode_id"] != right["episode_id"]
      changed << "goal" if left["goal"] != right["goal"]
      ActiveEpisode::FACT_KEYS.each do |key|
        changed << key if left.dig("facts", key) != right.dig("facts", key)
      end
      changed << "identifiers" if left["identifiers"] != right["identifiers"]
      changed << "pending_fact" if left["pending_fact"] != right["pending_fact"]
      changed << "pending_question" if left["pending_question"] != right["pending_question"]
      changed << "active_photo" if left["active_photo"] != right["active_photo"]
      changed << "conflicts" if left["conflicts"] != right["conflicts"]
      changed
    end

    def initialize(state:, text:, role:, now:, selection_turn:, pending_fact:, correlation_id:, channel:, enabled:, shared:, prior_user_turns: [], analysis: nil, account: nil)
      @raw_state = state
      @text = text
      @role = role
      @now = now
      @selection_turn = selection_turn
      @pending_override = pending_fact
      @correlation_id = correlation_id
      @channel = channel
      @enabled = enabled
      @shared = shared
      @prior_user_turns = Array(prior_user_turns)
      @analysis = analysis
      @account = account
      @normalized = FollowupQueryRewriter.normalize_label(text)
      @words = @normalized.split
      @measurement = false
      @unbound = false
      @budget = false
      @deictic = false
    end

    def call
      episode = self.class.coerce_episode(@raw_state, @now)
      apply_pending_override(episode)
      reason = skip_reason
      return result(:skipped, reason, episode, episode) if reason

      invalid = episode.reason == "invalid_state"
      current = episode.presence || ActiveEpisode.new
      return open_episode(:new_episode, current, goal: :when_substantive) if reset_explicit?

      if current.blank?
        if substantive? || (names_equipment? && @words.size >= 6)
          return open_episode(:opened, current, goal: :always)
        end

        return result(:no_episode, (invalid ? "invalid_state" : nil), ActiveEpisode.new, ActiveEpisode.new)
      end

      owned = apply_owned_slice(current)
      return owned if owned

      known = known_manufacturer(current)
      brands = find_brands
      other = other_brand(brands, known, current)

      if known && other && (correction? || brand_only?(other, known))
        return correct!(current, other)
      end
      if other && subject_brand?(other) && @words.size >= 6
        return open_episode(:new_episode, current, goal: :always)
      end
      # CG-D19 #D (medición 9, paso 5): «Ahora estoy revisando un KONE que no
      # nivela» after the brand was corrected to KONE is new work on the same
      # brand, not a clarification of the springs. The subject form decides,
      # exactly as it does for another brand.
      if known && brands == [ known ] && subject_brand?(known) && @words.size >= 6 && !correction?
        return open_episode(:new_episode, current, goal: :always)
      end
      if known && brands.any? { |brand| brand != known }
        return continue(current, :continued_mention, :no_brand, compose: elliptical?)
      end
      referent = technical_referent(current)
      return continue_with_referent(current, referent.text) if referent.resolved?
      return break_continuity(current) if referent.context_break?
      if referent.rejected?
        return continue(current, :continued_self_contained, :facts, compose: false, replace_goal: self_contained?, composed: :scope)
      end
      if elliptical?
        return continue(current, :continued_elliptical, :facts, compose: true)
      end

      continue(current, :continued_self_contained, :full, compose: false, replace_goal: true)
    end

    private

    def apply_pending_override(episode)
      return if @pending_override.equal?(FROM_STATE)
      return if episode.blank?

      episode.pending_fact = @pending_override
    end

    def skip_reason
      return "flag_off" unless @enabled
      return "non_web" unless @channel == "web"
      return "shared_session" if @shared
      return "selection_turn" if @selection_turn
      return "blank" if @text.strip.empty?
      return "not_user" unless @role == "user"

      nil
    end

    def apply_owned_slice(current)
      return nil unless Rag::HaikuQueryAnalysisFlag.conditional?

      perception = owned_perception(current)
      applied = owned_decision(current, perception)
      log_ownership(perception, applied)
      applied
    end

    def owned_perception(current)
      return @analysis if @analysis.is_a?(Rag::ConversationalTurnAnalysis)
      return :failed if @analysis == :failed

      Rag::SemanticQueryAnalyzer.observe_ownership(
        turn: @text,
        episode: current.to_h,
        correlation_id: @correlation_id
      ) || :failed
    end

    def owned_decision(current, perception)
      return fail_closed_shift(current) if perception == :failed && explicit_equipment_shift?(current)
      return nil unless perception.is_a?(Rag::ConversationalTurnAnalysis)
      return fail_closed_perception(current) if perception.relation == "unclear" && !continuity_followup?
      return nil unless %w[switch correct].include?(perception.relation)
      return fail_closed_perception(current) if perception.ambiguous
      return apply_switch(current, perception) if perception.relation == "switch" && literal_equipment?(perception)
      return apply_correct(current, perception) if perception.relation == "correct" && explicit_correction?

      nil
    end

    def fail_closed_shift(current)
      open_episode(:new_episode, current, goal: :always)
    end

    def fail_closed_perception(current)
      episode = current.fork
      episode.touch!(@now)
      episode.clear_fact!("model")
      episode.clear_fact!("manufacturer")
      if self_contained?
        episode.assign_goal!(@text, correlation_id: @correlation_id)
      else
        episode.clear_goal!
      end
      extract!(episode, :facts)
      finish(:continued_self_contained, current, episode, compose: false)
    end

    def apply_switch(current, perception)
      return fail_closed_perception(current) if unrecognized_equipment?(perception)
      return fail_closed_perception(current) if ambiguous_catalog_identity?(perception)

      episode = ActiveEpisode.open(correlation_id: @correlation_id, now: @now)
      episode.assign_goal!(@text, correlation_id: @correlation_id)
      extract!(episode, :full)
      write_catalog_identity!(episode, perception)
      finish(:new_episode, current, episode, compose: false)
    end

    def apply_correct(current, perception)
      episode = current.fork
      episode.touch!(@now)
      episode.clear_fact!("model")
      episode.clear_fact!("manufacturer")
      extract!(episode, :full)
      write_catalog_identity!(episode, perception)
      if self_contained?
        episode.assign_goal!(@text, correlation_id: @correlation_id)
      else
        episode.clear_goal!
      end
      finish(:corrected, current, episode, compose: false)
    end

    # A switch name with no catalog row and no manufacturer is not an identity.
    def unrecognized_equipment?(perception)
      return false unless @account
      return false if find_brands.any?

      spans = Array(perception.mentions).filter_map do |mention|
        next unless mention["role"] == "equipment"

        span = mention["span"].to_s
        span if span.present? && @text.downcase.include?(span.downcase)
      end
      return false if spans.empty?

      spans.all? { |span| KbDocumentResolver.resolve(span, account: @account).empty? }
    end

    def literal_equipment?(perception)
      Array(perception.mentions).any? do |mention|
        span = mention["span"].to_s
        span.present? && mention["role"] == "equipment" && @text.downcase.include?(span.downcase)
      end
    end

    # An elliptical next step with no named target stays on deterministic
    # continuity. "el otro" and a different equipment token stay fail-closed.
    def continuity_followup?
      return false unless elliptical?
      return false if @normalized.match?(/\botro\b/)
      return false if names_equipment?
      return false if @text.match?(/\b[A-Z][A-Za-z0-9-]{2,}\b/)

      true
    end

    def explicit_correction?
      correction? || MODEL_VALUE_RE.match?(@normalized) || find_brands.any?
    end

    def explicit_equipment_shift?(episode)
      known = known_manufacturer(episode)
      return true if other_brand(find_brands, known, episode)

      model = episode.fact("model")&.dig("value").to_s
      return false if model.blank?

      token = @text[/\b[A-Z][A-Za-z0-9-]{2,}\b/]
      token.present? && !token.casecmp?(model)
    end

    def ambiguous_catalog_identity?(perception)
      equipment_spans(perception).any? do |span|
        identity = catalog_identity_for(span)
        identity.is_a?(Hash) && identity["ambiguous"] == true
      end
    end

    def write_catalog_identity!(episode, perception)
      return unless @account

      equipment_spans(perception).each do |span|
        identity = catalog_identity_for(span)
        next unless identity.is_a?(Hash) && identity["model"].present?
        next if episode.fact("model")&.dig("status") == "known"

        episode.write_fact!(
          "model",
          status: "known",
          value: identity["model"],
          source: "user",
          correlation_id: @correlation_id,
          at: @now.iso8601
        )
        manufacturer = identity["manufacturer"]
        next if manufacturer.blank? || episode.fact("manufacturer")&.dig("status") == "known"

        episode.write_fact!(
          "manufacturer",
          status: "known",
          value: manufacturer,
          source: "user",
          correlation_id: @correlation_id,
          at: @now.iso8601
        )
      end
    end

    def equipment_spans(perception)
      Array(perception.mentions).filter_map do |mention|
        next unless mention["role"] == "equipment"

        span = mention["span"].to_s
        span if span.present? && @text.downcase.include?(span.downcase)
      end
    end

    def catalog_identity_for(span)
      return nil unless @account

      docs = Array(KbDocumentResolver.resolve_scoped(span, account: @account, limit: 20)).map do |item|
        item.respond_to?(:document) ? item.document : item
      end
      entries = docs.filter_map { |doc| Rag::DocumentIdentityCatalog.current.for_document(doc) }
      Rag::DocumentIdentityCatalog.consensus(entries, span)
    end

    def log_ownership(perception, applied)
      analysis = perception.is_a?(Rag::ConversationalTurnAnalysis) ? perception : nil
      relation = analysis&.relation
      ambiguous = analysis&.ambiguous
      eligible = analysis && ambiguous != true && relation != "unclear" && %w[switch correct].include?(relation)
      owned = eligible && applied&.decision == (relation == "switch" ? :new_episode : :corrected)
      Rails.logger.info({
        event: "haiku_ownership_slice",
        ownership_slice: "switch_correct",
        analysis_called: true,
        analysis_valid: !analysis.nil?,
        analysis_error: analysis.nil? ? (perception == :failed ? "failed" : "invalid") : nil,
        relation: relation,
        ambiguous: ambiguous,
        ownership_eligible: eligible,
        ownership_applied: owned
      }.to_json)
    end

    def reset_explicit?
      RESET_RE.match?(@normalized)
    end

    def correction?
      CORRECTION_RE.match?(@normalized)
    end

    def followup_marker?
      FOLLOWUP_RE.match?(@normalized) || FOLLOWUP_START_RE.match?(@normalized)
    end

    def find_brands
      MANUFACTURERS.select { |brand| @normalized.match?(/\b#{Regexp.escape(brand)}\b/) }
    end

    def other_brand(brands, known, episode)
      candidates = if known
        brands.reject { |brand| brand == known }
      elsif episode.pending_fact&.dig("subject") != "manufacturer"
        brands
      else
        []
      end
      candidates.size == 1 ? candidates.first : nil
    end

    def subject_brand?(brand)
      brand_re = /\b#{Regexp.escape(brand)}\b/
      offset = 0
      while (match = SUBJECT_RE.match(@normalized, offset))
        tail = @normalized[match.end(0)..]
        found = tail.match(brand_re)
        return true if found && tail[0...found.begin(0)].split.size <= 3

        offset = match.end(0)
      end
      false
    end

    def brand_only?(other, known)
      stripped = @normalized.dup
      [ known, other ].compact.each { |brand| stripped = stripped.gsub(/\b#{Regexp.escape(brand)}\b/, " ") }
      leftover = stripped.split.reject { |word| FILLER.include?(word) }
      leftover.empty? || correction?
    end

    def designators
      @designators ||= @text.scan(DESIGNATOR_RE).uniq.select { |token| KbDocumentResolver.specific_token?(token) }
    end

    def names_equipment?
      find_brands.any? || designators.any?
    end

    def self_contained?
      return @self_contained if defined?(@self_contained)

      @self_contained = FollowupQueryRewriter.explicit_question?(@text) &&
                        !followup_marker? &&
                        (names_equipment? || @words.size >= 6)
    end

    def elliptical?
      return false if self_contained?
      return true if followup_marker?
      return false unless FollowupQueryRewriter.closed_followup_shape?(@text)
      return false if new_task_statement?

      true
    end

    # A short turn that names another component is a new task. A brand, a
    # code, or "¿qué reviso primero?" stays a follow-up.
    def new_task_statement?
      TechnicalReferentResolver.independent_proposition?(@text)
    end

    def substantive?
      self_contained? || (!elliptical? && @words.size >= 6)
    end

    def known_manufacturer(episode)
      fact = episode.fact("manufacturer")
      return nil unless fact&.dig("status") == "known"

      FollowupQueryRewriter.normalize_label(fact["value"])
    end

    def open_episode(decision, before, goal:)
      episode = ActiveEpisode.open(correlation_id: @correlation_id, now: @now)
      assign = goal == :always || substantive? || @words.size >= 6
      episode.assign_goal!(@text, correlation_id: @correlation_id) if assign
      extract!(episode, :full)
      finish(decision, before, episode, compose: false)
    end

    def correct!(current, other)
      episode = current.fork
      episode.touch!(@now)
      episode.write_fact!(
        "manufacturer",
        status: "known",
        value: literal_phrase(other),
        source: "user",
        correlation_id: @correlation_id,
        at: @now.iso8601
      )
      episode.clear_fact!("model")
      episode.clear_identifiers!
      episode.clear_conflicts_for!("manufacturer")
      extract!(episode, :no_brand)
      finish(:corrected, current, episode, compose: true)
    end

    def continue(current, decision, mode, compose:, replace_goal: false, composed: nil)
      episode = current.fork
      episode.touch!(@now)
      episode.assign_goal!(@text, correlation_id: @correlation_id) if replace_goal
      extract!(episode, mode)
      composed = identity_scope_text(episode) if composed == :scope
      finish(decision, current, episode, compose: compose, composed: composed)
    end

    def finish(decision, before, episode, compose:, composed: nil)
      episode.clear_pending!
      composed = compose_text(episode) if composed.nil? && compose
      result(decision, outcome_reason(decision), before, episode, composed: composed)
    end

    def technical_referent(episode)
      goal = episode.goal
      TechnicalReferentResolver.call(
        text: @text,
        goal_text: goal&.dig("text"),
        goal_correlation_id: goal&.dig("correlation_id"),
        goal_truncated: episode.goal_truncated?,
        prior_turns: @prior_user_turns,
        now: @now
      )
    end

    def break_continuity(current)
      episode = current.fork
      episode.touch!(@now)
      if self_contained? || TechnicalReferentResolver.specified_component?(@text)
        episode.assign_goal!(@text, correlation_id: @correlation_id)
      else
        episode.clear_goal!
      end
      extract!(episode, :facts)
      finish(:continued_self_contained, current, episode, compose: false)
    end

    def continue_with_referent(current, expanded)
      episode = current.fork
      episode.touch!(@now)
      extract!(episode, :facts)
      finish(:continued_elliptical, current, episode, compose: false, composed: expanded)
    end

    def outcome_reason(decision)
      return "budget_exceeded" if @budget
      return "measurement_unbound" if @measurement
      return "unbound_unknown" if @unbound
      return "brand_mention_ignored" if decision == :continued_mention
      return "deictic_referent" if @deictic

      nil
    end

    def result(decision, reason, before, episode, composed: nil)
      Result.new(
        decision: decision,
        reason: reason,
        state: episode.to_h,
        composed: composed,
        fields_changed: decision == :skipped || decision == :no_episode ? [] : self.class.changed_fields(before, episode)
      )
    end

    def extract!(episode, mode)
      apply_closed_pending!(episode)
      pending = episode.pending_fact&.dig("subject")
      wrote = {}
      wrote["manufacturer"] = write_unknown_manufacturer(episode, pending) if mode != :no_brand
      wrote["model"] = write_unknown_model(episode, pending)
      wrote["fault_code"] = write_absent_code(episode)
      wrote["manufacturer"] ||= write_known_manufacturer(episode, pending) if mode != :no_brand
      wrote["model"] ||= write_known_model(episode, pending)
      wrote["fault_code"] ||= write_known_code(episode)
      append_identifiers(episode, wrote) if mode == :full
      @measurement = true if MEASUREMENT_RE.match?(@normalized)
      @deictic = true if DEICTIC_RE.match?(@normalized)
      @unbound = true if unbound_unknown?(pending, wrote)
    end

    def apply_closed_pending!(episode)
      parsed = PendingQuestion.parse_reply(
        @text,
        pending_question: episode.pending_question,
        pending_fact: episode.pending_fact
      )
      return unless parsed

      write_unresolved(episode, "fault_code", "absent_confirmed") if parsed["status"] == "absent"
      episode.clear_pending!
    end

    def write_unknown_manufacturer(episode, pending)
      return nil unless UNKNOWN_RE.match?(@normalized)
      return nil unless BRAND_WORD_RE.match?(@normalized) || pending == "manufacturer"

      write_unresolved(episode, "manufacturer", "unknown_confirmed")
    end

    def write_unknown_model(episode, pending)
      return nil unless UNKNOWN_RE.match?(@normalized) || NO_PLATE_RE.match?(@normalized)
      return nil unless MODEL_WORD_RE.match?(@normalized) || pending == "model"

      write_unresolved(episode, "model", "unknown_confirmed")
    end

    def write_absent_code(episode)
      return nil unless ABSENT_CODE_RE.match?(@normalized)

      write_unresolved(episode, "fault_code", "absent_confirmed")
    end

    def write_unresolved(episode, key, status)
      episode.write_fact!(key, status: status, source: "user", correlation_id: @correlation_id, at: @now.iso8601)
      true
    end

    def write_known_manufacturer(episode, pending)
      literal = if find_brands.size == 1
        literal_phrase(find_brands.first)
      elsif pending == "manufacturer" && @words.size <= 3 && @text.exclude?("?") && @text.exclude?("¿")
        @text.squish
      end
      return nil if literal.blank?

      episode.write_fact!("manufacturer", status: "known", value: literal, source: "user", correlation_id: @correlation_id, at: @now.iso8601)
      literal
    end

    def write_known_model(episode, pending)
      explicit = explicit_model_token
      token = explicit
      if token.nil? && pending == "model"
        single = @text.strip
        token = single if !single.match?(/\s/) && KbDocumentResolver.specific_token?(single)
      end
      return nil if token.blank?

      episode.write_fact!("model", status: "known", value: token, source: "user", correlation_id: @correlation_id, at: @now.iso8601)
      if explicit
        supersede_inherited_manufacturer!(episode)
        reaffirm_mentioned_identifiers!(episode)
      end
      token
    end

    # MODEL_VALUE_RE already requires the modelo/model frame. specific_token?
    # still accepts digit and all-caps designators. A mixed-case name is
    # accepted only inside that frame, and still has to clear length, shape,
    # stopword, and brand guards.
    def explicit_model_token
      token = @text.match(MODEL_VALUE_RE)&.[](1)
      return nil unless declared_model_token?(token)

      token
    end

    def declared_model_token?(token)
      return false if token.blank?
      return false if MODEL_DECLARATION_STOPWORDS.include?(token.downcase)
      return false if brand_token?(token)
      return true if KbDocumentResolver.specific_token?(token)

      token.length >= 4 && token.match?(/\A[A-Za-z][A-Za-z0-9\-]*\z/) &&
        token.match?(/[A-Z]/) && token.match?(/[a-z]/)
    end

    def brand_token?(token)
      label = FollowupQueryRewriter.normalize_label(token)
      MANUFACTURERS.include?(label) || KbDocumentResolver::BRANDS.include?(label)
    end

    # An explicit model is the identity of this turn. A manufacturer written
    # on an earlier turn was not restated, so it cannot keep classifying
    # other equipment as this job. A manufacturer written in this same turn
    # shares the correlation id and stays.
    def supersede_inherited_manufacturer!(episode)
      fact = episode.fact("manufacturer")
      return unless fact&.dig("status") == "known"
      return if fact["correlation_id"].to_s == @correlation_id.to_s

      episode.clear_fact!("manufacturer")
      episode.clear_conflicts_for!("manufacturer")
    end

    # Identifiers already carry correlation_id. A designator repeated in the
    # model declaration joins that turn. Ones left unsaid stay stored, but
    # their old correlation no longer counts as this job.
    def reaffirm_mentioned_identifiers!(episode)
      mentioned = designators.map { |token| FollowupQueryRewriter.normalize_label(token) }
      episode.identifiers.each do |item|
        label = FollowupQueryRewriter.normalize_label(item["value"])
        next unless mentioned.include?(label)

        item["correlation_id"] = @correlation_id.to_s
      end
    end

    def write_known_code(episode)
      code = @normalized.match(KNOWN_CODE_RE)&.[](3)
      return nil if code.blank?

      episode.write_fact!("fault_code", status: "known", value: code, source: "user", correlation_id: @correlation_id, at: @now.iso8601)
      code
    end

    def append_identifiers(episode, wrote)
      excluded = []
      excluded << FollowupQueryRewriter.normalize_label(wrote["manufacturer"]) if wrote["manufacturer"].is_a?(String)
      excluded << FollowupQueryRewriter.normalize_label(wrote["model"]) if wrote["model"].is_a?(String)
      excluded << FollowupQueryRewriter.normalize_label(wrote["fault_code"]) if wrote["fault_code"].is_a?(String)
      designators.each do |token|
        next if excluded.include?(FollowupQueryRewriter.normalize_label(token))

        episode.append_identifier!(token, correlation_id: @correlation_id)
      end
    end

    def unbound_unknown?(pending, wrote)
      return false unless UNKNOWN_RE.match?(@normalized)
      return false if pending.present?
      return false if BRAND_WORD_RE.match?(@normalized) || MODEL_WORD_RE.match?(@normalized) || CODE_WORD_RE.match?(@normalized)
      return false if wrote.values.any?

      true
    end

    def literal_phrase(phrase)
      words = phrase.split
      tokens = @text.scan(/[\p{L}\d]+/)
      norms = tokens.map { |token| FollowupQueryRewriter.normalize_label(token) }
      (0..(norms.length - words.length)).each do |index|
        next unless norms[index, words.length] == words

        return tokens[index, words.length].join(" ")
      end
      phrase
    end

    def compose_text(episode)
      goal_text = episode.goal&.dig("text")
      goal_text = nil if goal_text.blank? || episode.goal_truncated?
      goal_text = composed_problem(goal_text, episode) if goal_text
      visible_turn = retrieval_turn(episode)
      goal_text = nil if goal_text.present? && contains?(visible_turn, goal_text)
      items = identity_items(episode, goal_text, visible_turn)
      loop do
        lines = []
        lines << goal_text if goal_text
        lines << items.map(&:text).join(" ") if items.any?
        lines << visible_turn if visible_turn.present?
        composed = lines.join("\n")
        return composed if composed.length <= FollowupQueryRewriter::MAX_COMPOSED_CHARS

        identifier = items.rindex { |item| item.kind == :identifier }
        if identifier
          items.delete_at(identifier)
          next
        end
        model = items.index { |item| item.kind == :model }
        if model
          items.delete_at(model)
          next
        end
        if goal_text
          goal_text = nil
          next
        end

        @budget = true
        return nil
      end
    end

    # Historical goal stays as stored. The retrieval copy drops a catalog
    # manufacturer that is no longer the active one, which is the brand an
    # explicit correction replaced.
    def composed_problem(goal_text, episode)
      stale = stale_manufacturers(goal_text, user_known(episode, "manufacturer"))
      return goal_text if stale.empty?

      stripped = goal_text.dup
      stale.sort_by { |brand| -brand.length }.each do |brand|
        stripped = stripped.gsub(manufacturer_pattern(brand), " ")
      end
      stripped.squish
    end

    # A corrected turn already wrote Y. The negation sentence still contains X
    # and must not go to retrieval as a keyword.
    def retrieval_turn(episode)
      turn = @text.to_s.strip
      return turn unless correction?
      return turn if stale_manufacturers(turn, user_known(episode, "manufacturer")).empty?

      ""
    end

    def stale_manufacturers(text, active)
      return [] if active.blank?

      active_label = FollowupQueryRewriter.normalize_label(active)
      MANUFACTURERS.select { |brand| brand != active_label && contains?(text, brand) }
    end

    def manufacturer_pattern(brand)
      parts = brand.split.map { |part| Regexp.escape(part) }
      /\b#{parts.join('\s+')}\b/i
    end

    # A follow-up that names no model still has to retrieve inside the model
    # the catalog already confirmed. The goal itself is not pasted.
    def identity_scope_text(episode)
      parts = []
      manufacturer = user_known(episode, "manufacturer")
      model = user_known(episode, "model")
      parts << manufacturer if manufacturer.present? && !contains?(@text, manufacturer)
      parts << model if model.present? && !contains?(@text, model)
      return nil if parts.empty?

      "#{parts.join(" ")}\n#{@text.strip}"
    end

    def identity_items(episode, goal_text, visible_turn)
      items = []
      manufacturer = user_known(episode, "manufacturer")
      items << Item.new(:manufacturer, manufacturer) if manufacturer && !present_in?(goal_text, visible_turn, manufacturer)
      model = user_known(episode, "model")
      items << Item.new(:model, model) if model && !present_in?(goal_text, visible_turn, model)
      episode.identifiers.each do |identifier|
        next unless identifier["source"] == "user"
        next if present_in?(goal_text, visible_turn, identifier["value"])

        items << Item.new(:identifier, identifier["value"])
      end
      code = user_known(episode, "fault_code")
      label = "código #{code}" if code
      items << Item.new(:code, label) if label && !present_in?(goal_text, visible_turn, code) && !present_in?(goal_text, visible_turn, label)
      items
    end

    def user_known(episode, key)
      fact = episode.fact(key)
      return nil unless fact&.dig("status") == "known" && fact["source"] == "user"

      fact["value"]
    end

    def present_in?(goal_text, visible_turn, needle)
      contains?(goal_text, needle) || contains?(visible_turn, needle)
    end

    def contains?(haystack, needle)
      return false if haystack.blank? || needle.blank?

      normalized = FollowupQueryRewriter.normalize_label(haystack)
      label = FollowupQueryRewriter.normalize_label(needle)
      return false if label.blank?

      normalized.match?(/\b#{Regexp.escape(label)}\b/)
    end

    Item = Struct.new(:kind, :text)
  end
end
