# frozen_string_literal: true

module Rag
  # The only linguistic writer of the episode in owner mode. It does not write
  # Document Focus.
  class WorkContextReducer
    GENERIC_LED_STATE = /\A(?:el\s+)?led\s+est[aá]\s+(encendido|apagado)\z/i
    QUALIFIED_LED = /\A(?:el\s+)?led\s+(.+?)\s+est[aá]\s+(encendido|apagado)\z/i

    # A failed interpretation did not classify the turn. Keep the literal
    # report so the next turn still has this job. Do not write manufacturer,
    # model, controller, or any other extracted identity.
    def self.retain_uninterpreted_report!(episode:, turn:, correlation_id:, now:)
      return episode if continuity_request?(turn)
      return episode unless RoutePolicy.searchable_symptom?(turn)

      working = episode.presence || ActiveEpisode.open(correlation_id: correlation_id, now: now)
      working.touch!(now)
      literal = turn.to_s.squish
      working.assign_goal!(literal, correlation_id: correlation_id) if working.goal.blank?
      working.append_observation!(literal, correlation_id: correlation_id)
      working
    end

    # The interpreter rejected the turn as meta. A "no sé cómo…" answers the
    # published datum only when the turn names that datum, or names none.
    # A different datum stays an unknown and does not borrow the pending question.
    def self.remember_unknown_clarification!(episode:, turn:, correlation_id:, now:)
      return episode unless unknown_clarification?(turn)
      return episode if episode.nil? || episode.blank?

      published = published_documented_question(episode)
      shown = shown_documented_question(episode)
      episode.touch!(now)
      chosen = chosen_unknown_datum(published, shown, turn) if published || shown
      answers = { "r" => "unknown" }
      if chosen
        answers["q"] = chosen["question"]
        answers["t"] = chosen["targets"]
      end
      episode.append_observation!(turn.to_s.squish, correlation_id: correlation_id, answers: answers)
      if chosen && published && same_question_text?(chosen, published)
        clear_matching_pending!(episode, published["question"])
      elsif chosen && shown && same_question_text?(chosen, shown)
        clear_shown!(episode)
      end
      episode
    end

    def self.unknown_clarification?(turn)
      FollowupQueryRewriter.normalize_label(turn).match?(PendingQuestion::UNKNOWN_CLARIFICATION)
    end

    def self.published_documented_question(episode)
      pending = episode.pending_question
      if open_documented_question?(pending)
        return { "question" => pending["question"], "targets" => pending["targets"] }
      end

      Array(episode.observations).reverse_each do |item|
        answers = item["answers"]
        next unless open_answer?(answers)

        return { "question" => answers["q"], "targets" => answers["t"] }
      end
      nil
    end

    def self.open_documented_question?(pending)
      pending.is_a?(Hash) && pending["type"] == "documented_context" &&
        pending["aspect"] != "scope" && pending["question"].present? &&
        Array(pending["targets"]).any?
    end

    def self.open_answer?(answers)
      answers.is_a?(Hash) && answers["aspect"] != "scope" && answers["r"].blank? &&
        answers["q"].present? && Array(answers["t"]).any?
    end

    def self.settle_answered_pending!(episode, question)
      clear_matching_pending!(episode, question)
    end

    def self.clear_matching_pending!(episode, question)
      pending = episode.pending_question
      return unless closable_documented_question?(pending)
      return unless FollowupQueryRewriter.normalize_label(pending["question"]) ==
        FollowupQueryRewriter.normalize_label(question)

      shown = pending["shown"]
      promoted = promote_shown_question(pending, shown)
      if promoted
        episode.pending_question = promoted
      else
        episode.clear_pending!
      end
    end

    # A scope question is not the open #21 datum. The answer that belongs to
    # it still retires it. A different clarification kept in shown stays open.
    def self.closable_documented_question?(pending)
      return false unless pending.is_a?(Hash) && pending["type"] == "documented_context"
      return false if pending["question"].blank?
      return pending["about"].present? if pending["aspect"] == "scope"

      Array(pending["targets"]).any?
    end

    # The answered datum leaves. A different clarification that was published
    # with it, and that still has its targets, becomes the open question.
    def self.promote_shown_question(pending, shown)
      return nil unless shown.is_a?(Hash)

      text = shown["question"].to_s.squish
      return nil if text.blank?
      return nil if FollowupQueryRewriter.normalize_label(text) ==
        FollowupQueryRewriter.normalize_label(pending["question"])

      PendingQuestion.coerce(
        "type" => "documented_context",
        "question" => text,
        "targets" => shown["targets"]
      )
    end

    # The turn has to name the same entity, property, and scope. A shared
    # number or a shared root is not that. A bare "no sé" answers the open
    # question. This does not build a question from the turn or from a catalog.
    def self.same_published_datum?(question, turn)
      return false unless question.is_a?(Hash)
      return true if unspecified_reply?(turn)

      asked = datum_parts(question_datum_text(question))
      said = datum_parts(turn)
      return false if other_scope?(asked, said)
      return false if other_property?(asked, said)
      return false if other_entity?(asked, said)

      datum_covers?(asked, said)
    end

    # A short request to continue, with no component and no measurement.
    def self.continuity_request?(turn)
      label = FollowupQueryRewriter.normalize_label(turn)
      words = label.split
      return false if words.empty? || words.size > 6
      return false if designators(turn).any?
      return false unless words.any? { |word| CONTINUATION.include?(word) }

      words.all? { |word| CONTINUATION.include?(word) || CONTINUATION_FILLER.include?(word) }
    end

    def self.unspecified_reply?(turn)
      closed_reply?(turn) || unspecified_unknown?(turn)
    end

    def self.shown_documented_question(episode)
      shown = episode.pending_question.is_a?(Hash) ? episode.pending_question["shown"] : nil
      return nil unless shown.is_a?(Hash) && shown["question"].present?

      { "question" => shown["question"], "targets" => Array(shown["targets"]) }
    end

    def self.chosen_unknown_datum(published, shown, turn)
      if unspecified_reply?(turn)
        return nil if published && shown && !same_question_text?(published, shown)

        return published || shown
      end
      published_hit = published && same_published_datum?(published, turn)
      shown_hit = shown && same_published_datum?(shown, turn)
      return nil if published_hit && shown_hit
      return published if published_hit
      return shown if shown_hit

      nil
    end

    def self.same_question_text?(left, right)
      FollowupQueryRewriter.normalize_label(left["question"]) ==
        FollowupQueryRewriter.normalize_label(right["question"])
    end

    def self.clear_shown!(episode)
      pending = episode.pending_question
      return unless pending.is_a?(Hash) && pending["shown"]

      kept = pending.deep_dup
      kept.delete("shown")
      episode.pending_question = PendingQuestion.coerce(kept)
    end

    def self.question_datum_text(question)
      parts = [ question["question"].to_s ]
      Array(question["targets"]).each do |target|
        item = target.is_a?(Hash) ? target["item"].to_s : target.to_s
        parts << item if CompanionPlanRender.symptom_stems(item).size < 3
        designators(item).each { |number| parts << "##{number}" }
      end
      parts.join(" ")
    end

    def self.datum_parts(text)
      properties = []
      entities = []
      CompanionPlanCheck.words(text).each do |word|
        next if word.length < 4 || STEM_STOP.include?(word)

        stem = CompanionPlanCheck.stem(word)
        next if FRAME_STEMS.include?(stem) || generic_entity?(stem) || referent_placeholder?(stem)
        next if CompanionPlanCheck::CONNECTORS.include?(word) && property_stems.exclude?(stem)

        if property_stems.include?(stem)
          properties << stem
        else
          entities << stem
        end
      end
      Datum.new(designators(text), properties.uniq, entities.uniq)
    end

    def self.other_scope?(asked, said)
      return false if said.numbers.empty?

      asked.numbers.empty? || (asked.numbers & said.numbers).empty?
    end

    def self.other_property?(asked, said)
      asked.properties.any? && said.properties.any? && (asked.properties & said.properties).empty?
    end

    def self.other_entity?(asked, said)
      asked.entities.any? && said.entities.any? && (asked.entities & said.entities).empty?
    end

    def self.datum_covers?(asked, said)
      if asked.numbers.any?
        return false unless asked.numbers.all? { |number| said.numbers.include?(number) }
        return false if asked.properties.any? && (asked.properties & said.properties).empty?
        return false if asked.entities.any? && said.entities.any? && (asked.entities & said.entities).empty?

        return true
      end
      return false if said.numbers.any?

      entity_hit = (asked.entities & said.entities).any?
      property_hit = (asked.properties & said.properties).any?
      return false if asked.properties.any? && said.properties.any? && !property_hit
      return false if asked.entities.any? && said.entities.any? && !entity_hit

      entity_hit || property_hit
    end

    def self.unspecified_unknown?(turn)
      label = FollowupQueryRewriter.normalize_label(turn)
      return false unless label.match?(PendingQuestion::UNKNOWN_CLARIFICATION)
      return false if designators(turn).any?

      rest = label.sub(UNKNOWN_FRAME, "")
      parts = datum_parts(rest)
      parts.numbers.empty? && parts.properties.empty? && parts.entities.empty?
    end

    def self.property_stems
      @property_stems ||= %w[
        activada encendido apagado abierto cerrado continuidad voltaje tension
        corriente resistencia parpadeante obstruida presion
      ].map { |word| CompanionPlanCheck.stem(word) }.to_set
    end

    def self.generic_entity?(stem)
      CompanionPlanRender::GENERIC_STEMS.include?(stem) || %w[equip siste].include?(stem)
    end

    # "parte" names no component. "mientras" is a connective, not an entity.
    # A property word that the plan checker also lists as a connective stays.
    def self.referent_placeholder?(stem)
      REFERENT_PLACEHOLDERS.include?(stem)
    end

    def self.designators(text)
      text.to_s.scan(/#?\d+/).map { |token| token.delete("#") }.uniq
    end

    def self.closed_reply?(turn)
      FollowupQueryRewriter.normalize_label(turn).match?(CLOSED_REPLY)
    end

    Datum = Struct.new(:numbers, :properties, :entities)
    CLOSED_REPLY = /\A(?:si|no|no se|no lo se|no puedo verlo)\z/
    UNKNOWN_FRAME = /\Ano (?:lo )?se(?:\s+como|\s+distingu\w*|\s+ver|\s+si)?\b/
    STEM_STOP = %w[el la los las un una unos unas del que esta estan este como para por con].to_set
    FRAME_STEMS = %w[disti ident saber recon decir neces orien infor].to_set
    REFERENT_PLACEHOLDERS = %w[parte].to_set
    CONTINUATION = %w[sigue seguir seguimos siguiente ahora luego entonces despues proximo hago hacemos].to_set
    CONTINUATION_FILLER = %w[que como cual cuando donde y o a el la lo los las un una me te se por para con del].to_set
    private_class_method :unknown_clarification?, :published_documented_question,
      :open_documented_question?, :open_answer?, :clear_matching_pending!,
      :closable_documented_question?,
      :shown_documented_question, :chosen_unknown_datum, :same_question_text?, :clear_shown!,
      :question_datum_text, :datum_parts, :other_scope?, :other_property?, :other_entity?,
      :datum_covers?, :unspecified_unknown?, :promote_shown_question, :generic_entity?,
      :referent_placeholder?,
      :designators, :closed_reply?

    def self.apply!(episode:, perception:, decision:, turn:, correlation_id:, now:)
      new(
        episode: episode, perception: perception, decision: decision,
        turn: turn, correlation_id: correlation_id, now: now
      ).apply!
    end

    def initialize(episode:, perception:, decision:, turn:, correlation_id:, now:)
      @episode = episode
      @perception = perception
      @decision = decision
      @turn = turn.to_s
      @correlation_id = correlation_id
      @now = now
    end

    def apply!
      return @episode if @perception.nil?
      return @episode if @decision&.decision == "meta"

      write_checks unless @perception.move == "unclear"
      bind_documented_answer
      remember_referent_choice if remember_referent_choice?
      promote_carry if promote_existing_carry?

      if @decision&.decision == "clarify_first"
        @episode.touch!(@now)
        return @episode if @perception.move == "new_work"
        return @episode if @perception.move == "unclear" && documented_pending?

        preserve_referent_opening if opening_referent?
        write_pending(@decision.pending_question)
        return @episode
      end
      return @episode if @perception.move == "unclear"

      apply_negations
      write_assertions
      write_replacement_fault_code
      write_absent_fault_code
      write_observations unless @decision&.decision == "clarify_first"
      assign_goal_if_needed
      clear_pending_unless_meta
      @episode.touch!(@now)
      @episode
    end

    private

    def answer_promotes_carry?
      @perception.move == "answer_pending" && %w[value unknown seek].include?(@perception.pending_resolution)
    end

    def promote_existing_carry?
      return true if answer_promotes_carry?
      return false unless %w[follow_up correct].include?(@perception.move)

      conversational_pending?
    end

    def conversational_pending?
      PendingQuestion::CONVERSATIONAL_TYPES.include?(@episode.pending_question&.dig("type"))
    end

    def promote_carry
      Array(@episode.pending_question&.dig("carry")).each do |span|
        @episode.append_identifier!(span, correlation_id: @correlation_id, source: "user")
      end
    end

    def opening_referent?
      @perception.move == "unclear" &&
        @perception.clarification_target == "referent" &&
        !referent_pending?
    end

    def referent_pending?
      @episode.pending_question&.dig("type") == "referent"
    end

    # Stated assertions stay. The observation stays the doubt, not an identity.
    # The goal is that doubt, not the whole turn.
    def documented_pending?
      @episode.pending_question&.dig("type") == "documented_context"
    end

    def preserve_referent_opening
      write_assertions
      @perception.observations.each do |text|
        @episode.append_observation!(text, correlation_id: @correlation_id)
      end
      assign_referent_goal
    end

    def assign_referent_goal
      return if @episode.goal.present?

      phrase = goal_observations.join(" ").squish
      return if phrase.blank?

      @episode.assign_goal!(phrase, correlation_id: @correlation_id)
    end

    def remember_referent_choice?
      referent_pending? && @decision&.performs_retrieval?
    end

    def remember_referent_choice
      choice = PendingQuestion.referent_choice(@perception, @turn)
      return if choice.blank?

      @episode.append_identifier!(choice, correlation_id: @correlation_id, source: "user")
    end

    def apply_negations
      @perception.identities.select { |item| item.kind == "negate" && item.slot.present? }.each do |item|
        if item.slot == "identifier"
          remove_identifier(item.span)
          @episode.append_rejected!("identifier", item.span)
        elsif ActiveEpisode::FACT_KEYS.include?(item.slot)
          fact = @episode.fact(item.slot)
          value = fact&.dig("value").presence || item.span
          if item.slot == "controller" && @episode.fact("manufacturer")&.dig("source") == "catalog"
            strip_value(@episode.fact("manufacturer")["value"], slot: "manufacturer")
            @episode.clear_fact!("manufacturer")
          end
          @episode.clear_fact!(item.slot)
          @episode.append_rejected!(item.slot, value)
          remove_identifier(value)
          remove_identifier("código #{value}") if item.slot == "fault_code"
          strip_value(value, slot: item.slot)
        end
      end
    end

    def write_assertions
      @perception.facts.each do |item|
        @episode.delete_rejected!(item.slot, item.value)
        @episode.write_fact!(
          item.slot,
          status: "known",
          value: item.value,
          source: item.source.presence || "user",
          correlation_id: @correlation_id,
          at: @now.iso8601
        )
        next if item.manufacturer.blank? || item.slot == "manufacturer"
        next if controller_brand_replaces_equipment?(item)
        next if declared_manufacturer?

        @episode.delete_rejected!("manufacturer", item.manufacturer)
        @episode.write_fact!(
          "manufacturer",
          status: "known",
          value: item.manufacturer,
          source: "catalog",
          correlation_id: @correlation_id,
          at: @now.iso8601
        )
      end
      if @perception.move == "answer_pending" && @perception.pending_resolution == "unknown"
        slot = pending_slot
        if %w[manufacturer model controller].include?(slot)
          @episode.write_fact!(slot, status: "unknown_confirmed", source: "user", correlation_id: @correlation_id, at: @now.iso8601)
        end
      elsif @perception.move == "answer_pending" && @perception.pending_resolution == "absent"
        @episode.write_fact!("fault_code", status: "absent_confirmed", source: "user", correlation_id: @correlation_id, at: @now.iso8601)
      end
      @perception.identifiers.each do |item|
        next unless durable_identifier?(item.value)
        next if identifier_repeats_check_result?(item.value)

        @episode.delete_rejected!("identifier", item.value)
        @episode.append_identifier!(item.value, correlation_id: @correlation_id, source: "user")
      end
    end

    def identifier_repeats_check_result?(value)
      label = FollowupQueryRewriter.normalize_label(value)
      return false if label.blank?

      Array(@perception.checks).any? { |check|
        item = check.is_a?(Hash) ? check.stringify_keys : {}
        FollowupQueryRewriter.normalize_label(item["result"]) == label
      }
    end

    def bind_documented_answer
      question = @episode.pending_question
      return unless question.is_a?(Hash) && question["type"] == "documented_context"
      return if @perception.move == "meta"

      if @perception.move == "new_work"
        @episode.clear_pending!
        return
      end

      reply = PendingQuestion.parse_reply(@turn, pending_question: question)
      code = reply.is_a?(Hash) ? reply["r"] : nil
      scope = scope_question?(question)
      return if @perception.move == "unclear" && code.nil?
      return if next_step_question?
      if ambiguous_open_referent? || ambiguous_named_referent?
        if unknown_limit_reply?
          @episode.append_observation!(
            @turn.to_s.squish, correlation_id: @correlation_id, answers: { "r" => "unknown" }
          )
        end
        return
      end

      answers = { "q" => question["question"].to_s, "t" => Array(question["targets"]) }
      if scope
        answers["about"] = question["about"]
        answers["aspect"] = "scope"
      elsif code
        answers["r"] = code
      end
      texts = Array(@perception.observations).map { |text| text.to_s.squish }.compact_blank
      if texts.empty? && (code || @perception.move == "answer_pending" || (scope && closed_scope_turn?))
        literal = @turn.to_s.squish.first(160)
        texts = [ literal ] if literal.present?
      end
      return if texts.empty?

      return unless scope || self.class.same_published_datum?(question, @turn)

      texts.each { |text| @episode.append_observation!(text, correlation_id: @correlation_id, answers: answers) }
      self.class.settle_answered_pending!(@episode, question["question"])
    end

    def next_step_question?
      self.class.continuity_request?(@turn)
    end

    def ambiguous_open_referent?
      shown = @episode.pending_question.is_a?(Hash) ? @episode.pending_question["shown"] : nil
      return false unless shown.is_a?(Hash) && shown["question"].present?

      self.class.unspecified_reply?(@turn)
    end

    # The reply fits both open matters. It stays unbound so the next plan
    # can ask which stored question it answers.
    def ambiguous_named_referent?
      pending = @episode.pending_question
      shown = pending.is_a?(Hash) ? pending["shown"] : nil
      return false unless shown.is_a?(Hash) && shown["question"].present?

      self.class.same_published_datum?(pending, @turn) &&
        self.class.same_published_datum?(shown, @turn)
    end

    def unknown_limit_reply?
      label = FollowupQueryRewriter.normalize_label(@turn)
      label == "no puedo verlo" || label.match?(/\Ano (?:lo )?se\b/)
    end

    def scope_question?(question)
      question["aspect"] == "scope" && question["about"].present?
    end

    # "Sí" answers a yes/no choice. It does not say what was reviewed.
    def closed_scope_turn?
      label = FollowupQueryRewriter.normalize_label(@turn)
      PendingQuestion::DOCUMENTED_REPLIES.key?(label) || label.match?(PendingQuestion::UNKNOWN_CLARIFICATION)
    end

    # A controller brand fills an empty equipment manufacturer. It does not
    # replace one already stored.
    def controller_brand_replaces_equipment?(item)
      return false unless item.slot == "controller"

      current = @episode.fact("manufacturer")&.dig("value")
      return false if current.blank?

      FollowupQueryRewriter.normalize_label(current) != FollowupQueryRewriter.normalize_label(item.manufacturer)
    end

    def write_observations
      return if %w[meta clarify_first].include?(@decision&.decision)

      @perception.observations.each do |text|
        @episode.append_observation!(text, correlation_id: @correlation_id)
      end
      supersede_retracted_observations
    end

    def write_checks
      return unless @perception.respond_to?(:checks)

      Array(@perception.checks).each do |check|
        @episode.upsert_check!(check_with_operation(check), correlation_id: @correlation_id)
      end
    end

    # The family is the act verb closest before the subject in the sentence
    # that contains it. No such verb is the check family. The full sentence
    # stays available to ReportedOperation.correspondence through the literal span.
    def check_with_operation(check)
      item = check.is_a?(Hash) ? check.stringify_keys : {}
      subject = item["subject"].to_s
      sentence = @turn.to_s.split(/(?<=[.!?])\s+/).find { |part|
        SessionContextBuilder.companion_sentence_has?(part, subject)
      } || @turn.to_s
      family = ReportedOperation.family_before(sentence, subject)
      item.merge("operation" => [ family || "check" ])
    end

    # A correction names the replacement as a mention when the turn has no
    # manufacturer, model, or controller fact. The reducer adopts that mention
    # onto the negated fault-code slot. It does not invent a code meaning.
    def write_replacement_fault_code
      return unless @perception.move == "correct"
      return if @episode.fact("fault_code")&.dig("status") == "known"

      negated = @perception.identities.select { |item| item.kind == "negate" && item.slot == "fault_code" }
      return if negated.empty?

      negated_labels = negated.map { |item| FollowupQueryRewriter.normalize_label(item.value.presence || item.span) }
      mention = @perception.mentions.find { |item|
        label = FollowupQueryRewriter.normalize_label(item.value.presence || item.span)
        label.match?(TurnPerception::FAULT_RE) && negated_labels.exclude?(label)
      }
      return if mention.nil?

      value = (mention.value.presence || mention.span).to_s
      @episode.delete_rejected!("fault_code", value)
      @episode.write_fact!(
        "fault_code",
        status: "known",
        value: value,
        source: "user",
        correlation_id: @correlation_id,
        at: @now.iso8601
      )
    end

    # "No aparece código de falla" is a report, not an answer to a pending slot.
    # Reuse the fallback absence phrase. Do not replace a known code.
    def write_absent_fault_code
      return if @perception.identities.any? { |item| item.kind == "negate" && item.slot.blank? }

      current = @episode.fact("fault_code")
      return if current && %w[known absent_confirmed].include?(current["status"])

      text = ([ @turn ] + Array(@perception.observations)).join(" ")
      return unless FollowupQueryRewriter.normalize_label(text).match?(ActiveEpisodeTurn::ABSENT_CODE_RE)

      @episode.write_fact!(
        "fault_code",
        status: "absent_confirmed",
        source: "user",
        correlation_id: @correlation_id,
        at: @now.iso8601
      )
    end

    def declared_manufacturer?
      source = @episode.fact("manufacturer")&.dig("source").to_s
      %w[user photo].include?(source)
    end

    def supersede_retracted_observations
      correction = @perception.respond_to?(:correction) ? @perception.correction : nil
      if correction&.active?
        targets = ObservationCorrection.targets(@episode.observations, correction)
        return if targets.nil? || targets == :ambiguous

        phrases = remembered_assertions(correction, targets)
        phrases.each { |phrase| remember_asserted!(phrase) }
        drop_unqualified_led!(phrases)
        if phrases.any? { |phrase| asserted_stored?(phrase) }
          if targets.one?
            correction.retracted.each { |phrase| excise_selected_observation(targets.first, phrase, phrases) }
          elsif targets.size > 1
            targets.each { |item|
              correction.retracted.each { |phrase| excise_selected_observation(item, phrase, phrases) }
            }
          else
            correction.retracted.each { |phrase| excise_retracted_phrase(phrase, phrases) }
          end
          correction.retracted.each { |phrase| excise_retracted_goal(phrase, phrases) }
          drop_replaced_observations(phrases)
          adopt_problem_goal!(phrases)
        end
        return
      end

      # "Corrijo" can replace one word without a retractive tail. A changed
      # number is not that replacement; the tail handles floors and indicators.
      return unless @turn.match?(/\bcorrijo\b/i)

      fresh = Array(@perception.observations).map { |text| text.to_s.squish }
      drop_replaced_observations(fresh)
      adopt_problem_goal!(fresh)
    end

    def drop_replaced_observations(fresh)
      @episode.observations.reject! { |item|
        text = item["text"].to_s
        next false if fresh.any? { |phrase| same_label?(phrase, text) }

        fresh.any? { |phrase| observation_replaced?(text, phrase) }
      }
    end

    # A generic "el LED está apagado" keeps the single retracted LED's
    # qualifier. Two qualified LEDs, or an assertion that already names one,
    # stay as the technician wrote them.
    def remembered_assertions(correction, targets)
      source = targets.one? ? targets.first : nil
      correction.asserted.map { |phrase| preserve_led_referent(phrase, source) }
    end

    def self.qualify_generic_led(phrase, source)
      state = phrase.to_s.squish[GENERIC_LED_STATE, 1]
      qualifier = source.to_s.squish[QUALIFIED_LED, 1]
      return phrase if state.blank? || qualifier.blank?

      "LED #{qualifier} está #{state}"
    end

    def preserve_led_referent(phrase, source)
      self.class.qualify_generic_led(phrase, source)
    end

    def drop_unqualified_led!(phrases)
      states = phrases.filter_map { |phrase| phrase.to_s.squish[QUALIFIED_LED, 2] }
      return if states.empty?

      @episode.observations.reject! { |item|
        state = item["text"].to_s.squish[GENERIC_LED_STATE, 1]
        state.present? && states.any? { |kept| kept.casecmp?(state) }
      }
    end

    # A sentence that still names the retracted value is not the replacement.
    # "está encendido, no apagado" contains the new state and is removed with
    # the old observation, so the replacement has to be stored on its own.
    def remember_asserted!(phrase)
      return if asserted_stored?(phrase, durable: true)

      @episode.append_observation!(phrase, correlation_id: @correlation_id)
    end

    def asserted_stored?(phrase, durable: false)
      label = FollowupQueryRewriter.normalize_label(phrase)
      return false if label.blank?

      @episode.observations.any? { |item|
        current = FollowupQueryRewriter.normalize_label(item["text"])
        next false unless current == label || contained_label?(label, current) || contained_label?(current, label)
        next false if durable && current != label && retracted_carrier?(item["text"])

        true
      }
    end

    def retracted_carrier?(text)
      correction = @perception.respond_to?(:correction) ? @perception.correction : nil
      return false unless correction&.active?

      correction.retracted.any? { |nucleus|
        ObservationCorrection.retracted?(text, nucleus, correction.asserted)
      }
    end

    def contained_label?(inner, outer)
      return false if inner.blank? || outer.blank? || inner == outer

      outer.match?(/(?<![[:alnum:]])#{Regexp.escape(inner)}(?![[:alnum:]])/)
    end

    def excise_retracted_phrase(phrase, asserted)
      @episode.observations.map! { |item|
        next item unless ObservationCorrection.retracted?(item["text"], phrase, asserted)

        excise_observation_clauses(item, phrase, asserted)
      }
      @episode.observations.compact!
    end

    def excise_selected_observation(selected, phrase, asserted)
      @episode.observations.map! { |item|
        next item unless item["text"] == selected

        excise_observation_clauses(item, phrase, asserted)
      }
      @episode.observations.compact!
    end

    def excise_observation_clauses(item, phrase, asserted)
      kept = independent_clauses(item["text"]).reject { |clause|
        ObservationCorrection.retracted?(clause, phrase, asserted)
      }
      return if kept.empty?

      item.merge("text" => kept.join(" y "))
    end

    def excise_retracted_goal(phrase, asserted)
      return unless @episode.goal.is_a?(Hash)

      text = @episode.goal["text"].to_s
      return unless ObservationCorrection.retracted?(text, phrase, asserted)

      kept = goal_clauses(text).reject { |clause|
        ObservationCorrection.retracted?(clause, phrase, asserted)
      }
      if kept.empty? || kept.none? { |clause| problem_statement?(clause) }
        @episode.clear_goal!
      else
        @episode.goal["text"] = kept.select { |clause| problem_statement?(clause) }.join(" y ")
      end
    end

    def independent_clauses(text)
      text.to_s.split(/\s+y\s+/i).map(&:squish).compact_blank
    end

    # A stored observation is one clause. " y " inside that sentence is not
    # the boundary that separates it from the next observation.
    def goal_clauses(text)
      protected_text, masks = mask_goal_observations(text)
      pieces = protected_text.split(/\s+y\s+/i).map(&:squish).compact_blank
      pieces.map { |piece| unmask_goal(piece, masks) }
    end

    def mask_goal_observations(text)
      protected_text = text.to_s.dup
      masks = []
      phrases = @episode.observations.filter_map { |item| item["text"].to_s.squish.presence }.uniq
      phrases.sort_by! { |phrase| -phrase.length }
      phrases.each_with_index do |phrase, index|
        next unless protected_text.include?(phrase)

        token = "\u0000OBS#{index}\u0000"
        protected_text = protected_text.sub(phrase, token)
        masks << [ token, phrase ]
      end
      [ protected_text, masks ]
    end

    def unmask_goal(piece, masks)
      masks.reduce(piece) { |current, (token, phrase)| current.gsub(token, phrase) }
    end

    def same_label?(left, right)
      FollowupQueryRewriter.normalize_label(left) == FollowupQueryRewriter.normalize_label(right)
    end

    # Same sentence with one replaced word. A changed number is a different
    # referent unless the turn retracts it with "no de". Shared words alone
    # do not make two observations the same correction.
    def observation_replaced?(old_text, new_text)
      old_words = FollowupQueryRewriter.normalize_label(old_text).split
      new_words = FollowupQueryRewriter.normalize_label(new_text).split
      return false unless old_words.size == new_words.size && old_words.any?

      changed = old_words.zip(new_words).select { |left, right| left != right }
      return false unless changed.size == 1

      left, right = changed.first
      return false if numeric_token?(left) || numeric_token?(right)

      true
    end

    def numeric_token?(word)
      word.match?(/\A\d+\z/)
    end

    def assign_goal_if_needed
      return if @episode.goal.present?
      return unless @decision&.performs_retrieval?
      return unless %w[report follow_up new_work].include?(@perception.move)

      @episode.assign_goal!(durable_goal_text, correlation_id: @correlation_id)
    end

    # A validated symptom from this turn is the durable problem. The raw turn
    # stays the fallback when the interpreter returned no symptom.
    def durable_goal_text
      phrases = goal_observations
      return @turn if phrases.empty?

      problems = phrases.select { |phrase| problem_statement?(phrase) }
      (problems.any? ? problems : phrases).join(" ")
    end

    def goal_observations
      seen = {}
      phrases = Array(@perception.observations).filter_map { |text|
        phrase = text.to_s.squish
        next if phrase.blank? || ObservationText.continuity_echo?(phrase)

        label = FollowupQueryRewriter.normalize_label(phrase)
        next if label.blank? || seen[label]

        seen[label] = true
        phrase
      }

      kept = []
      phrases.each do |phrase|
        candidate = (kept + [ phrase ]).join(" ")
        break if kept.any? && candidate.length > ActiveEpisode::MAX_GOAL_CHARS

        kept << phrase
      end
      kept
    end

    def clear_pending_unless_meta
      return if @decision&.decision == "meta"
      return if @perception.move == "meta"
      return if open_documented_pending?

      @episode.clear_pending!
    end

    # The published question stays until a corresponding answer clears it.
    # A later "qué sigue" or an unrelated report does not remove it.
    def open_documented_pending?
      question = @episode.pending_question
      question.is_a?(Hash) && question["type"] == "documented_context"
    end

    def write_pending(question)
      @episode.clear_pending!
      coerced = PendingQuestion.coerce(question)
      return if coerced.nil?

      @episode.pending_question = coerced
      return unless PendingQuestion::FACT_TYPES.include?(coerced["type"])

      @episode.pending_fact = { "subject" => coerced["type"], "correlation_id" => @correlation_id.to_s }
    end

    def pending_slot
      type = @episode.pending_question&.dig("type")
      return type if type.present?

      @episode.pending_fact&.dig("subject")
    end

    # Symptom sentences are observations. Stored as identifiers they push the
    # equipment tokens out of the fixed list, and the prompt loses the machine
    # after the history trim. A digit inside the sentence is not a designator.
    # A catalog fact, an identity slot, or a designator token still stays when
    # the observation names that equipment.
    def durable_identifier?(value)
      words = value.to_s.squish.split
      return false if words.size >= 4

      label = FollowupQueryRewriter.normalize_label(value)
      return false if label.blank?
      return true unless observation_mentions?(label)

      equipment_identity?(value, label)
    end

    def equipment_identity?(value, label)
      return true if catalog_or_slot_span?(label)

      designator_token?(value)
    end

    def catalog_or_slot_span?(label)
      @perception.identities.any? { |item|
        item.act == "assert" && recorded_identity?(item) && span_label?(item, label)
      }
    end

    def recorded_identity?(item)
      item.source == "catalog" || %w[manufacturer model controller].include?(item.slot)
    end

    def span_label?(item, label)
      [ item.span, item.value ].any? { |text| FollowupQueryRewriter.normalize_label(text) == label }
    end

    # TechnicalReferentResolver.designator_only? treats a bare number as a
    # specific token. A separated digit is a floor or an indicator state.
    def designator_token?(value)
      tokens = value.to_s.scan(/[\p{L}\d][\p{L}\d\-]*/)
      return false if tokens.empty? || tokens.any? { |token| token.match?(/\A\d+\z/) }

      TechnicalReferentResolver.designator_only?(value)
    end

    def observation_mentions?(label)
      @perception.observations.any? { |text|
        FollowupQueryRewriter.normalize_label(text).match?(/(?<![[:alnum:]])#{Regexp.escape(label)}(?![[:alnum:]])/)
      }
    end

    def remove_identifier(value)
      label = FollowupQueryRewriter.normalize_label(value)
      @episode.identifiers.reject! { |item| FollowupQueryRewriter.normalize_label(item["value"]) == label }
    end

    def strip_value(value, slot:)
      return if value.blank?

      if @episode.goal.is_a?(Hash)
        text = SlotRejection.excise_text(@episode.goal["text"], slot, value)
        if text.blank?
          @episode.clear_goal!
        elsif text != @episode.goal["text"].to_s.squish
          @episode.goal["text"] = text
        end
      end
      @episode.observations.reject! { |item|
        SlotRejection.attributable?(item["text"], slot, value)
      }
      adopt_problem_goal! if slot.to_s == "fault_code"
    end

    # "El display muestra" is what remains after the code is removed. It is
    # not the job. A stored check becomes the goal only when the episode
    # already has one. A later explicit new job still opens its own episode.
    def adopt_problem_goal!(preferred = [])
      clear_residual_goal!
      return if problem_goal?

      phrase = Array(preferred).find { |text| problem_statement?(text) }
      row = if phrase
        { "text" => phrase, "correlation_id" => @correlation_id }
      else
        @episode.observations.find { |item| problem_statement?(item["text"]) }
      end
      return if row.nil?

      @episode.assign_goal!(row["text"], correlation_id: row["correlation_id"].presence || @correlation_id)
    end

    def clear_residual_goal!
      return unless @episode.goal.is_a?(Hash)
      return if problem_statement?(@episode.goal["text"])

      @episode.clear_goal!
    end

    def problem_goal?
      @episode.goal.is_a?(Hash) && problem_statement?(@episode.goal["text"])
    end

    def problem_statement?(text)
      normalized = FollowupQueryRewriter.normalize_label(text)
      return false if normalized.blank?

      TechnicalUnderstanding::SIGNAL_RE.match?(normalized)
    end
  end
end
