# frozen_string_literal: true

module Rag
  # Deterministic check of one companion plan. A link joins a case fact to a
  # source statement; its reading may only use words of that statement, of
  # the case, and connectives. A step must be a step statement. The question
  # must use words of the sources or the case and must not ask what the case
  # already says. A check or perception verb, and a short word before a
  # grounded word, are conversational. A -mente word next to such a verb is
  # a method: the original question stays rejected, and one unambiguous
  # report can still be clarified from the documentary check. That
  # clarification asks what the technician looked at. It keeps the report,
  # including a negation, and it does not ask whether that thing is present.
  # An invalid part is dropped with its reason; the rest stays.
  # This is lexical. It does not prove that a reading is semantically right.
  class CompanionPlanCheck
    MAX_LINKS = 4
    MAX_STEPS = 4
    MAX_READING_CHARS = 320
    MAX_QUESTION_CHARS = 240
    LINKABLE = %w[step item text warning].freeze

    CONNECTORS = %w[
      a al ante bajo cada como con contra cual cuales cuando de del desde donde e el ella ellas ello ellos en entre
      esa esas ese eso esos esta estas este esto estos hacia hasta la las le les lo los mas me mi mientras muy ni no
      o os otra otras otro otros para pero por porque que quien se segun si sin sobre su sus tambien tan te tu tus
      un una uno unos unas y ya aun asi entonces tanto solo mismo misma ademas igual
      es son estar esta estan sea ser hay haya queda quedan quede sigue siguen seguir puede pueden podria
      tiene tienen tener vale implica significa apunta senala deja dejan
      caso tecnico danebo lectura dijiste reportaste informaste
      posible posibles posibilidad abierta abierto pendiente pendientes opcion alternativa restante restantes
      explica explicaria coincide compatible encaja
    ].to_set.freeze
    QUESTION_WORDS = %w[
      que cual cuales como donde cuando hay tenes tienes tiene ves veis podes puedes sabes notas ocurre pasa sucede
      aparece aparecen alguno alguna algun algo ahora momento vez veces siempre durante todavia esta estan
      conectado conectada conectados conectadas instalado instalada
    ].to_set.freeze
    PERCEPTION = %w[veo ves vi vemos noto notas observo].to_set.freeze
    NEGATION = /\b(?:no|ni|nunca|sin|tampoco|ningun[oa]?)\b/
    EXCLUSION = /\b(?:descart\w*|exclu\w*|elimin\w*|no es (?:la|el) (?:causa|problema)|quedan? fuera|no influye|no afecta|ya no|no hace falta|innecesari\w*|no tiene que ver)\b/
    ORDER = /\b(?:primer[oa]?|lo primero|antes de|despues|luego|siguiente paso|por ultimo|finalmente|mas probable|probablemente|probable|principal\w*|prioridad|priorit\w*|urgente|empez\w*|comenz\w*)\b/
    PRESCRIPTION = /\b(?:hay que|tenes que|tienes que|debes|deberias|deberia|conviene|recomiendo|te recomiendo|asegurate)\b/
    OPERATION = /\b(?:ajust|gir|rot|aument|reduc|sub|baj|calibr|regul|cambi|reemplaz|sustitu|puente|desconect|conect|med|mid|puls|presion|apret|limpi|muev|mov|forz|reinici|reset)(?:ar|er|ir|aste|iste|a|e|i|as|es|alo|elo|arlo|erlo|irlo|ando|iendo|ala|ela)\b/
    STATUS = /\b(?:comprob|verific|revis|confirm|cheque|prob|realiz)(?:ad[oa]s?|aste|aron|amos|o|e)\b|\bya (?:lo )?(?:hiciste|hizo|hice)\b/
    CHECK_OBJECT = /\A(?:comprobar|verificar|revisar|controlar|observar|mirar|asegurar)\b(?:\s+que)?(?:\s+no\s+hay)?\s+/i
    # The verb in the question follows the act the technician already used.
    # A bare "veo" has no check verb: the question asks what was looked at.
    SCOPE_VERBS = {
      "revis" => "revisaste",
      "observ" => "observaste",
      "comprob" => "comprobaste",
      "verific" => "verificaste",
      "mir" => "miraste",
      "control" => "controlaste",
      "cheque" => "chequeaste"
    }.freeze
    SCOPE_QUESTION = /\ADijiste «([^»]+)»\. ¿Qué (?:#{Regexp.union(SCOPE_VERBS.values).source})\?\z/
    SIGHT_REASK = /\Aves\b|\bes lo que ves\z/

    Result = Data.define(
      :links, :steps, :question, :rejections, :associations, :confirmed_items,
      :question_targets, :limits, :omissions, :question_scope, :question_role
    ) do
      def usable?
        links.any? || steps.any? || limits.any? || (question.present? && question_targets.any?)
      end

      def to_h
        {
          "links" => links.map { |link| link.transform_keys(&:to_s) },
          "steps" => steps,
          "question" => question,
          "rejections" => rejections,
          "associations" => associations.map { |row| row.transform_keys(&:to_s) },
          "confirmed_items" => confirmed_items,
          "question_targets" => question_targets,
          "limits" => limits,
          "omissions" => omissions,
          "question_scope" => question_scope,
          "question_role" => question_role
        }
      end
    end

    def self.call(plan, facts:, statements:, turns: [])
      new(plan, facts, statements, turns).call
    end

    def self.words(text)
      I18n.transliterate(text.to_s.unicode_normalize(:nfc)).downcase
          .gsub(/(\p{L})-(\p{L})/, '\1\2')
          .scan(/[a-z0-9]+/)
    end

    def self.stem(word)
      word.match?(/\A\d/) || word.length < 5 ? word : word[0, 5]
    end

    def self.normal(text)
      words(text).join(" ")
    end

    def self.question_stems
      QUESTION_WORDS.map { |word| stem(word) }.to_set
    end

    def initialize(plan, facts, statements, turns)
      @plan = plan.is_a?(Hash) ? plan.deep_stringify_keys : {}
      @facts = facts
      @statements = statements
      @turns = Array(turns)
      @rejections = []
    end

    def call
      @associations = []
      @limits = []
      @omissions = []
      @confirmed = {}
      links = check_links
      apply_corrections!
      collapse_associations!
      candidates = candidate_steps
      @targets = valid_targets
      steps = select_steps(candidates)
      question, targets = resolve_question(steps)
      note_missing_targets
      Result.new(
        links: links, steps: steps, question: question, rejections: @rejections,
        associations: @associations, confirmed_items: @confirmed,
        question_targets: question.present? ? targets : [],
        limits: @limits, omissions: @omissions,
        question_scope: question.present? ? @question_scope : nil,
        question_role: question.present? ? @question_role : nil
      )
    end

    private

    def check_links
      kept = []
      Array(@plan["links"]).each do |raw|
        link = raw.is_a?(Hash) ? raw.stringify_keys : {}
        fact = @facts.find(link["fact"])
        statement = @statements.find(link["statement"])
        reading = link["reading"].to_s.squish
        reason = if fact.nil? then "unknown_fact"
        elsif statement.nil? then "unknown_statement"
        elsif LINKABLE.exclude?(statement.kind) then "statement_kind:#{statement.kind}"
        elsif kept.any? { |item| item[:statement] == statement.id && item[:fact] == fact.id } then "duplicate"
        elsif kept.size >= MAX_LINKS then "over_limit"
        end
        relation = nil
        if reason.nil? && check_fact?(fact) && statement.step?
          relation = ReportedOperation.correspondence(
            report_text: fact.text, result: fact.result,
            status: fact.done_check? ? "done" : "not_done",
            statement_text: statement.text
          )
          reason = "operation_mismatch" if %i[none related].include?(relation)
        end
        case_relation = reason.nil? ? remember_case(fact, statement) : nil
        reason ||= reading_reason(reading, fact, statement) if reading.present?
        reason ||= "case_incompatible" if case_relation&.relation == :incompatible
        reason ||= "case_unresolved" if case_relation&.relation == :unresolved && statement.step?
        if reason.nil? && (led = led_context_reason(fact, statement))
          reason = led
          @led_report = fact.text
        end
        if reason
          reject("link", link, reason)
          next
        end
        kept_link = { fact: fact.id, statement: statement.id, reading: reading.presence }
        kept_link[:relation] = relation if relation
        kept << kept_link
      end
      kept
    end

    def candidate_steps
      kept = []
      Array(@plan["steps"]).each do |id|
        statement = @statements.find(id)
        reason = if statement.nil? then "unknown_statement"
        elsif !statement.step? then "not_a_step"
        elsif kept.include?(statement.id) then "duplicate"
        elsif kept.size >= MAX_STEPS then "over_limit"
        end
        next reject("step", id, reason) if reason

        kept << statement.id
      end
      kept
    end

    def select_steps(candidates)
      steps = []
      candidates.each do |id|
        reason = step_reason(id)
        if reason
          reject("step", id, reason)
        else
          steps << id
          confirm_item(@statements.find(id))
        end
      end
      steps
    end

    # An incompatible relation vetoes the step on every path, including a
    # matching heading, a link, or a yes. A question does not import it.
    def step_reason(id)
      statement = @statements.find(id)
      return "unknown_statement" unless statement

      item = statement.item.to_s
      relation = relation_of(item)
      return "case_incompatible" if relation == :incompatible
      return "case_excluded_by_answer" if answer_code(item, statement) == "no"
      return nil if answer_code(item, statement) == "yes" || item_applicable?(item) || relation == :compatible

      if answer_code(item, statement) == "unknown" || relation == :unresolved
        remember_limit(statement) if answer_code(item, statement) == "unknown"
        return "case_unresolved"
      end

      "case_unconfirmed"
    end

    def item_applicable?(item)
      CompanionPlanRender.applicable?(item, @facts)
    end

    def check_fact?(fact)
      fact.done_check? || fact.kind == "not_done_check"
    end

    def resolve_question(steps)
      remember_unknown_item_limit
      text = @plan["question"].to_s.squish
      targets = @targets
      reason = text.present? ? question_reason(text, steps) : nil
      reason = "repeats_heading" if reason.nil? && text.present? && heading_repeat?(text)
      if text.present? && declared_unknown_question?(text)
        reject("question", text, "declared_unknown")
        remember_declared_limit(targets)
        return [ nil, [] ]
      end
      if text.present? && reason.nil?
        note_led_context_question(steps, text)
        return accepted_question(text, bound_targets(text, targets))
      end

      reject("question", text, reason || "invalid") if text.present?
      if led_context_open? && (text.blank? || reason)
        clarified = led_context_clarification(steps)
        if clarified && question_reason(clarified.first, steps).nil?
          @question_role = "led_context"
          return accepted_question(*clarified)
        end
      end
      if reason.to_s.start_with?("modality:")
        clarified = clarify_report(text)
        return accepted_question(*clarified) if clarified

        return [ nil, [] ]
      end
      derived_from = replacement_items(reason, text)
      return [ nil, [] ] unless derived_from.any? && derived_from.all? { |item| !closed_target?(item) }

      partial = open_partial_for(derived_from)
      if partial
        concrete = derived_from.one? ? concrete_question(derived_from.first, partial) : nil
        return accepted_question(concrete, derived_from.map(&:id)) if concrete.present? && question_reason(concrete, steps).nil?

        remember_partial_limit(derived_from.first, partial)
        return [ nil, [] ]
      end
      return [ nil, [] ] unless text.blank? || derivable?(reason)

      derived = derived_question(derived_from)
      return [ nil, [] ] if derived.blank? || question_reason(derived, steps)

      accepted_question(derived, derived_from.map(&:id))
    end

    def accepted_question(text, targets)
      assign_scope(text)
      [ text, targets ]
    end

    # Only a question that quotes one stored observation and asks the scope
    # of that report. A symptom choice does not set this.
    def assign_scope(question)
      report = question.to_s[SCOPE_QUESTION, 1]
      return if report.blank?
      return unless @facts.facts.any? { |fact| fact.kind == "observation" && fact.text == report }

      @question_scope = { "report" => report, "aspect" => "scope" }
    end

    # A blank question, a soft wording failure, or a restatement of the
    # heading can be replaced. A closed answer cannot.
    def replacement_items(reason, text)
      from_targets = item_target_statements
      replaceable = text.blank? || derivable?(reason) || %w[repeats_ask repeats_heading].include?(reason)
      return from_targets if from_targets.any? && replaceable
      return unresolved_items if text.blank? || %w[repeats_ask repeats_heading].include?(reason)

      []
    end

    # The heading, or a prior question, restated after an open partial.
    # A choice between the item's two nouns is a narrower question.
    def heading_repeat?(text)
      open_partial_rows.any? do |statement, fact|
        next false if part_choice?(text, statement)

        asked = content_stems(self.class.words(text)) - self.class.question_stems
        next false if asked.empty?

        item_stems = content_stems(self.class.words(statement.text))
        prior = content_stems(self.class.words(fact.answers["q"].to_s)) - self.class.question_stems
        asked.subset?(item_stems) || (prior.any? && asked.subset?(prior))
      end
    end

    def part_choice?(text, statement)
      nouns = distinct_nouns(statement.text)
      return false if nouns.size < 2

      body = self.class.normal(text)
      body.match?(/\bo\b/) && nouns.first(2).all? { |noun| body.include?(self.class.normal(noun)) }
    end

    # Uses the partial answer. Two documentary nouns become the choice.
    # The heading is not the question. Nil when that choice is not available.
    def concrete_question(statement, partial)
      nouns = distinct_nouns(statement.text)
      return nil if nouns.size < 2

      left, right = nouns
      words = self.class.words(partial.text)
      if words.include?("parte")
        "¿Qué parte se está cerrando, #{left} o #{right}?"
      elsif words.any? { |word| self.class.stem(word) == "cerra" }
        "¿Se está cerrando #{left} o #{right}?"
      end
    end

    def distinct_nouns(text)
      article_nouns(text).uniq { |phrase| self.class.stem(self.class.words(phrase).last.to_s) }
    end

    def article_nouns(text)
      text.to_s.scan(/\p{L}+/).each_cons(2).filter_map do |left, right|
        article = self.class.words(left).first
        next unless CompanionCaseRelation::ARTICLES.include?(article)

        "#{article} #{right}"
      end
    end

    def open_partial_for(statements)
      statements.lazy.filter_map { |statement| open_partial(statement) }.first
    end

    def open_partial_rows
      @statements.statements.filter_map { |statement|
        partial = open_partial(statement)
        [ statement, partial ] if partial
      }
    end

    def open_partial(statement)
      item = statement.kind == "item" ? statement.text : statement.item.to_s
      @facts.facts.find { |fact|
        answers = fact.answers
        answers.is_a?(Hash) && answers["q"].present? && answers["r"].blank? &&
          answers["aspect"] != "scope" &&
          fact.kind == "observation" &&
          Array(answers["t"]).any? { |target| target_matches?(target, item, statement) }
      }
    end

    def remember_partial_limit(statement, partial)
      item = statement.text.to_s
      return if item.blank? || @limits.any? { |row| row["item"] == item && row["note"] == "partial" }

      @limits << {
        "item" => item, "source" => statement.source, "note" => "partial", "fact" => partial.text.to_s
      }
    end

    def derivable?(reason)
      value = reason.to_s
      value == "too_long" || value == "not_one_question" || value.start_with?("ungrounded:")
    end

    # The model's method is already rejected. The replacement quotes the
    # report and asks what that report covered. It does not ask whether the
    # documentary object is what the technician sees.
    def clarify_report(text)
      observation = unique_report(text)
      unless observation
        reject("clarification", text, @report_matches.to_i > 1 ? "several_reports" : "no_report")
        return nil
      end
      step = clarification_step(text, observation)
      unless step
        reject("clarification", text, "no_step")
        return nil
      end
      focus = check_object(step.text)
      parent = parent_of(step)
      unless focus.present? && parent
        reject("clarification", text, focus.present? ? "no_item" : "no_focus")
        return nil
      end
      verb = scope_verb(observation.text)
      unless verb
        reject("clarification", observation.text, "no_scope")
        return nil
      end

      question = "Dijiste «#{observation.text}». ¿Qué #{verb}?"
      reason = question_reason(question, [])
      if reason
        reject("clarification", question, reason)
        return nil
      end

      [ question, [ parent.id ] ]
    end

    def scope_verb(text)
      found = self.class.words(text).filter_map { |word| scope_verb_for(word) }.uniq
      return nil if found.many?
      return found.first if found.one?
      return "revisaste" if self.class.words(text).any? { |word| PERCEPTION.include?(word) }

      nil
    end

    def scope_verb_for(word)
      SCOPE_VERBS.each do |prefix, verb|
        next unless word.start_with?(prefix)

        rest = word.delete_prefix(prefix)
        next if rest.empty?
        return verb if rest.match?(ReportedOperation::FINITE) || rest.match?(ReportedOperation::PARTICIPLE)
      end
      nil
    end

    def unique_report(text)
      asked = report_stems(text)
      rows = @facts.facts.select { |fact| fact.kind == "observation" && report_stems(fact.text).intersect?(asked) }
      @report_matches = rows.size
      rows.one? ? rows.first : nil
    end

    def clarification_step(text, observation)
      cited = @rejections.filter_map { |row|
        next unless row["part"] == "question_about" && row["reason"].to_s.start_with?("statement_kind:")

        step = @statements.find(row["value"])
        step if step&.step? && report_step?(step, observation)
      }
      return cited.first if cited.one?
      return nil if cited.many?

      rows = @statements.statements.select { |step|
        step.step? && report_step?(step, observation) &&
          report_stems(step.text).intersect?(report_stems(text))
      }
      rows.one? ? rows.first : nil
    end

    def report_step?(step, observation)
      anchor = CompanionCaseRelation.first_anchor_stem(step.text)
      anchor.present? && report_stems(observation.text).include?(anchor)
    end

    def parent_of(step)
      @statements.statements.find { |item|
        item.kind == "item" && item.source == step.source && item.text == step.item
      }
    end

    def check_object(text)
      body = text.to_s.sub(CHECK_OBJECT, "").split(/[.;]/).first.to_s.squish
      body.presence
    end

    def report_stems(text)
      content_stems(self.class.words(text)) - CompanionPlanRender::GENERIC_STEMS
    end

    def valid_targets
      ids = Array(@plan["question_about"]).map(&:to_s).compact_blank.uniq
      if ids.size > 2
        reject("question_about", ids, "over_limit")
        return []
      end

      ids.select do |id|
        statement = @statements.find(id)
        if statement.nil? || %w[item text].exclude?(statement.kind)
          reject("question_about", id, statement.nil? ? "unknown_statement" : "statement_kind:#{statement.kind}")
          false
        else
          true
        end
      end
    end

    def item_target_statements
      @targets.filter_map { |id|
        statement = @statements.find(id)
        statement if statement&.kind == "item"
      }.first(2)
    end

    def unresolved_items
      rows = @statements.statements.select { |statement|
        statement.kind == "item" && relation_of(statement.text) == :unresolved && !closed_target?(statement)
      }.uniq(&:text)
      rows.one? ? rows : []
    end

    def derived_question(statements)
      rows = Array(statements).first(2)
      return nil if rows.empty?
      return one_target_question(rows.first) if rows.one?

      left, right = rows
      "¿Lo que ves coincide con «#{left.text}» [#{left.source}] o con «#{right.text}» [#{right.source}]?"
    end

    def one_target_question(statement)
      "¿Lo que ves coincide con «#{statement.text}» [#{statement.source}]?"
    end

    def remember_case(fact, statement)
      return nil unless fact&.kind == "observation"
      return nil unless case_target?(statement)

      relation = CompanionCaseRelation.call(
        fact_text: fact.text, item_text: item_text_for(statement), goal_text: @facts.goal&.text
      )
      @associations << association_row(fact, statement, relation)
      relation
    end

    def case_target?(statement)
      return false unless statement
      return true if statement.kind == "item"
      return false unless %w[step text].include?(statement.kind)

      item = statement.item.to_s
      item.present? && !item_applicable?(item)
    end

    def item_text_for(statement)
      statement.kind == "item" ? statement.text : statement.item.to_s
    end

    def association_row(fact, statement, relation)
      {
        fact: fact.id, statement: statement.id, item: item_text_for(statement),
        source: statement.source, relation: relation.relation, reason: relation.reason,
        anchors: relation.anchors
      }
    end

    def apply_corrections!
      corrections = @facts.facts.select { |fact|
        fact.kind == "observation" && CompanionCaseRelation.explicit_correction?(fact.text)
      }
      return if corrections.empty?

      item_statements.each do |statement|
        corrections.each do |fact|
          relation = CompanionCaseRelation.call(
            fact_text: fact.text, item_text: statement.text, goal_text: @facts.goal&.text
          )
          next if relation.relation == :unresolved && %w[no_anchor anchor_missing].include?(relation.reason)

          @associations.reject! { |row| row[:item] == statement.text }
          @associations << association_row(fact, statement, relation)
        end
      end
    end

    def item_statements
      @statements.statements.select { |statement| statement.kind == "item" }.uniq(&:text)
    end

    def collapse_associations!
      @associations = @associations.group_by { |row| row[:item] }.map { |_item, rows|
        rows.find { |row| row[:relation] == :incompatible } ||
          rows.find { |row| row[:relation] == :compatible } ||
          rows.first
      }
    end

    def relation_of(item)
      @associations.find { |row| row[:item] == item.to_s }&.dig(:relation)
    end

    def confirm_item(statement)
      item = statement.item.to_s
      return if item.blank?

      if item_applicable?(item)
        @confirmed[item] = "goal"
      elsif (row = @associations.find { |assoc| assoc[:item] == item && assoc[:relation] == :compatible })
        @confirmed[item] = row[:fact]
      elsif answer_code(item, statement) == "yes"
        @confirmed[item] = answer_fact(item, statement, "yes")&.id
      end
    end

    def remember_limit(statement)
      item = statement.item.to_s
      return if item.blank? || @limits.any? { |row| row["item"] == item }

      @limits << { "item" => item, "source" => statement.source }
    end

    # The technician already said this question cannot be identified. Do not
    # ask it again and do not replace it with a choice between two citations.
    def declared_unknown_question?(text)
      normal = self.class.normal(text)
      return false if normal.blank?

      asked = designators(text)
      @facts.facts.any? { |fact|
        answers = fact.answers
        next false unless answers.is_a?(Hash) && answers["r"].to_s == "unknown"
        next true if self.class.normal(answers["q"].to_s) == normal

        asked.any? && asked.intersect?(designators("#{answers["q"]} #{fact.text}"))
      }
    end

    def designators(text)
      text.to_s.scan(/#?\d+/).map { |token| token.delete("#") }.uniq
    end

    def remember_unknown_item_limit
      @facts.facts.each do |fact|
        answers = fact.answers
        next unless answers.is_a?(Hash) && answers["r"].to_s == "unknown"

        Array(answers["t"]).each do |target|
          item = target.is_a?(Hash) ? target["item"].to_s : target.to_s
          next if item.blank?

          statement = @statements.statements.find { |row|
            row.kind == "item" && row.text.to_s.squish == item.squish
          }
          remember_limit(statement) if statement
        end
      end
    end

    def remember_declared_limit(target_ids)
      Array(target_ids).filter_map { |id| @statements.find(id) }.each do |statement|
        remember_limit(statement)
      end
    end

    def answer_code(item, statement)
      codes = answer_facts(item, statement).filter_map { |fact|
        next if fact.answers["aspect"] == "scope"

        code = fact.answers["r"].to_s
        code if %w[yes no unknown].include?(code)
      }
      return "no" if codes.include?("no")
      return "yes" if codes.include?("yes")
      return "unknown" if codes.include?("unknown")

      nil
    end

    def answer_fact(item, statement, code)
      answer_facts(item, statement).find { |fact| fact.answers["r"].to_s == code }
    end

    def answer_facts(item, statement)
      @facts.facts.select { |fact|
        answers = fact.answers
        answers.is_a?(Hash) && Array(answers["t"]).any? { |target| target_matches?(target, item, statement) }
      }
    end

    def target_matches?(target, item, statement)
      text = target.is_a?(Hash) ? target["item"] : target
      normal = self.class.normal(text)
      return false if normal.blank?
      return false unless normal == self.class.normal(item) || normal == self.class.normal(statement&.text)

      page = target.is_a?(Hash) ? target["page"].to_s : ""
      page.blank? || statement.nil? || statement.page.to_s == page
    end

    def closed_target?(statement)
      item = statement.kind == "item" ? statement.text : statement.item.to_s
      return true if %w[yes no unknown].include?(answer_code(item, statement))

      %i[compatible incompatible].include?(relation_of(item))
    end

    def already_answered?
      return false if @targets.blank?

      @targets.any? { |id| (statement = @statements.find(id)) && closed_target?(statement) }
    end

    def repeated_ask?(normal)
      @facts.facts.any? { |fact|
        question = fact.answers.is_a?(Hash) ? fact.answers["q"] : nil
        question.present? && self.class.normal(question) == normal
      }
    end

    def note_missing_targets
      @facts.facts.each do |fact|
        next unless fact.answers.is_a?(Hash)

        Array(fact.answers["t"]).each do |target|
          text = target.is_a?(Hash) ? target["item"].to_s : target.to_s
          next if text.blank? || statement_present?(text)
          next if @omissions.any? { |row| row["item"] == text }

          @omissions << { "item" => text, "reason" => "target_not_loaded" }
        end
      end
    end

    def statement_present?(text)
      normal = self.class.normal(text)
      @statements.statements.any? { |statement|
        self.class.normal(statement.text) == normal || self.class.normal(statement.item) == normal
      }
    end

    LED_QUALIFIER = /\b(estado|status|fotoc[eé]lula)\b/i
    LED_WORD = /\bled\b/i

    # A generic "LED encendido" is not the Estado indicator and it is not
    # blinking. The link stays out. A later question can ask which LED
    # when the loaded manual names more than one.
    def led_context_reason(fact, statement)
      return nil unless fact&.kind == "observation"
      return nil unless generic_led_report?(fact.text)
      return nil unless led_statement?(statement)
      return nil if led_qualifiers(statement).all? { |stem| fact_led_stems(fact.text).include?(stem) }

      "led_context"
    end

    def led_context_open?
      @rejections.any? { |row| row["part"] == "link" && row["reason"] == "led_context" }
    end

    # The accepted question stays the pending question. Which indicator is a
    # separate line and does not take that slot.
    def note_led_context_question(steps, accepted)
      return unless led_context_open?

      clarified = led_context_clarification(steps)
      return if clarified.nil?

      question = clarified.first.to_s
      return if question.blank? || question == accepted
      return if question_reason(question, steps)

      reject("led_context_question", question, "led_context")
    end

    def led_context_clarification(_steps)
      labels = led_indicator_labels
      return nil if labels.size < 2

      state = ObservationCorrection.led_state(@led_report.to_s)
      return nil if state.blank?

      question = "¿Cuál LED está #{state}, el de #{labels[0]} o el de #{labels[1]}?"
      [ question, led_indicator_ids ]
    end

    def generic_led_report?(text)
      ObservationCorrection.led_state(text).present? && !text.to_s.match?(LED_QUALIFIER)
    end

    def led_statement?(statement)
      blob = "#{statement.item} #{statement.text}"
      blob.match?(LED_WORD) && (blob.match?(LED_QUALIFIER) || blob.match?(/\bparpadeante\b/i))
    end

    def led_qualifiers(statement)
      "#{statement.item} #{statement.text}".scan(LED_QUALIFIER).flatten.map { |word|
        self.class.stem(self.class.words(word).first.to_s)
      }.uniq
    end

    def fact_led_stems(text)
      self.class.words(text).map { |word| self.class.stem(word) }.to_set
    end

    def led_indicator_labels
      led_indicators.map { |statement| statement.text.to_s.sub(/[.\s]+\z/, "") }
    end

    def led_indicator_ids
      led_indicators.map(&:id)
    end

    def led_indicators
      @statements.statements.filter_map { |statement|
        next unless statement.kind == "item"
        next unless statement.text.to_s.match?(LED_QUALIFIER)

        sibling = @statements.statements.find { |other|
          other.item == statement.text && other.text.to_s.match?(LED_WORD)
        }
        next unless sibling

        statement
      }.uniq { |statement| self.class.stem(self.class.words(statement.text).first.to_s) }.first(2)
    end

    def reading_reason(reading, fact, statement)
      return "too_long" if reading.length > MAX_READING_CHARS
      return "question_in_reading" if reading.include?("?")

      normal = self.class.normal(reading)
      source = self.class.normal([ statement.text, statement.item, statement.section ].compact.join(" "))
      case_text = self.class.normal(@facts.facts.map { |item| [ item.text, item.result ].compact.join(" ") }.join(" "))
      lexical = forbidden(normal, source)
      return lexical if lexical
      return "operation" if normal.match?(OPERATION) && !(statement.step? && operation_in?(normal, source))
      return "status_claim" if status_claim?(normal)

      allowed = stems(source) | stems(case_text)
      missing = ungrounded(normal, allowed)
      return "ungrounded:#{missing.first(3).join(',')}" if missing.any?
      return "negation_not_grounded" unless negations_grounded?(normal, [ source, *case_texts ])
      return "dropped_alternative" if dropped_alternative?(normal, source)

      nil
    end

    def question_reason(text, steps)
      return "too_long" if text.length > MAX_QUESTION_CHARS
      return "not_one_question" unless text.end_with?("?") && text.count("?") == 1
      return "already_answered" if already_answered?

      normal = self.class.normal(text)
      return "repeats_ask" if repeated_ask?(normal)
      sight = negated_sight(normal)
      return "presence_reask:#{sight.id}" if sight

      repeated = repeated_fact(normal)
      return "operation" if repeated == :different_act
      return "repeats_fact:#{repeated.id}" if repeated

      sources = self.class.normal(@statements.statements.map { |item| [ item.text, item.item ].compact.join(" ") }.join(" "))
      case_text = self.class.normal((@facts.facts.map(&:text) + @turns).join(" "))
      return "exclusion" if normal.match?(EXCLUSION)
      return "prescription" if normal.match?(PRESCRIPTION)

      step_text = self.class.normal(steps.map { |id| @statements.find(id).text }.join(" "))
      return "operation" if normal.match?(OPERATION) && !operation_in?(normal, step_text)

      allowed = stems(sources) | stems(case_text) | QUESTION_WORDS.map { |word| self.class.stem(word) }.to_set
      applicable = stems(self.class.normal(applicable_manner_text(steps))) | stems(case_text)
      cited = text.scan(/\[(\d+)\]/).flatten.to_set
      missing, manner = question_gaps(normal.split, allowed, cited, applicable)
      return "ungrounded:#{missing.first(3).join(',')}" if missing.any?
      return "modality:#{manner.first(3).join(',')}" if manner.any?

      nil
    end

    # "¿Ves agua?" or "¿es lo que ves?" asks again for something the
    # technician already said is absent. Quoting that report inside a scope
    # question does not match this pattern.
    def negated_sight(normal)
      return nil unless normal.match?(SIGHT_REASK)

      asked = content_stems(normal.split) - self.class.question_stems
      return nil if asked.empty?

      @facts.facts.find { |fact|
        fact.kind == "observation" && negated_report?(fact.text) &&
          content_stems(self.class.words(fact.text)).intersect?(asked)
      }
    end

    def negated_report?(text)
      self.class.words(text).any? { |word| word.match?(NEGATION) }
    end

    # A -mente word is a method unless the cited step or the case states it.
    # Another statement that happens to contain the same stem does not.
    def question_gaps(words, allowed, cited, applicable)
      missing = []
      manner = []
      words.each_with_index do |word, index|
        stem = self.class.stem(word)
        next if CONNECTORS.include?(word) || cited.include?(word) || cited.include?(stem)
        if manner_word?(word, words, index) && applicable.exclude?(stem)
          manner << word
        elsif allowed.include?(stem) || conversational_word?(word, words, index, allowed)
          next
        else
          missing << word
        end
      end
      [ missing.uniq, manner.uniq ]
    end

    # The cited statement, or the kept step the question is about. A manner
    # word in a different step does not make the method applicable.
    def applicable_manner_text(steps)
      cited = Array(@plan["question_about"]).filter_map { |id| @statements.find(id)&.text }
      return cited.join(" ") if cited.any?

      asked = content_stems(self.class.words(@plan["question"].to_s).reject { |word| word.end_with?("mente") })
      steps.filter_map { |id|
        step = @statements.find(id)
        step.text if step && content_stems(self.class.words(step.text)).intersect?(asked)
      }.join(" ")
    end

    def conversational_word?(word, words, index, allowed)
      return true if familiar_stems.include?(self.class.stem(word))
      return true if ReportedOperation.family_of(word) == "check"

      nxt = words[index + 1]
      word.length < 5 && nxt.present? && allowed.include?(self.class.stem(nxt))
    end

    def manner_word?(word, words, index)
      return false unless word.end_with?("mente")
      return false if familiar_stems.include?(self.class.stem(word.delete_suffix("mente")))

      window = words[[ index - 3, 0 ].max..[ index + 3, words.size - 1 ].min]
      window.any? { |item| item != word && (ReportedOperation.family_of(item) || PERCEPTION.include?(item)) }
    end

    def familiar_stems
      @familiar_stems ||= (PERCEPTION.to_a + QUESTION_WORDS.to_a + CONNECTORS.to_a).map { |item| self.class.stem(item) }.to_set
    end

    # Each negated word of the reading follows a negation, within three
    # words, in the statement or in a case fact.
    def negations_grounded?(normal, texts)
      negated(normal).all? do |stem|
        texts.any? { |text| negated(text).include?(stem) }
      end
    end

    def negated(normal)
      words = normal.split
      words.each_with_index.flat_map do |word, index|
        next [] unless word.match?(/\A#{NEGATION.source}\z/)

        words[(index + 1)..(index + 3)].to_a.reject { |item| CONNECTORS.include?(item) }.first(1).map { |item| self.class.stem(item) }
      end.to_set
    end

    def case_texts
      @case_texts ||= @facts.facts.map { |item| self.class.normal([ item.text, item.result ].compact.join(" ")) }
    end

    def forbidden(normal, source)
      { "exclusion" => EXCLUSION, "order" => ORDER, "prescription" => PRESCRIPTION }.each do |name, pattern|
        normal.scan(pattern).each do |hit|
          phrase = hit.is_a?(Array) ? hit.compact.first : hit
          return name unless source.include?(phrase.to_s)
        end
      end
      nil
    end

    def operation_in?(normal, source)
      operations = normal.to_enum(:scan, OPERATION).map { Regexp.last_match(0) }
      operations.all? { |word| source.split.any? { |other| self.class.stem(other) == self.class.stem(word) } }
    end

    def status_claim?(normal)
      claims = normal.to_enum(:scan, STATUS).map { Regexp.last_match(0) }
      return false if claims.empty?

      done = @facts.facts.select(&:done_check?).map { |fact| self.class.normal(fact.text) }.join(" ")
      claims.any? { |claim| claim.split.none? { |word| done.include?(self.class.stem(word)) } }
    end

    def dropped_alternative?(normal, source)
      return false unless source.match?(/\bo\b/)
      return false if normal.match?(/\bo\b/)

      before, after = source.split(/\bo\b/, 2)
      left = content_stems(before.to_s.split.last(3))
      right = content_stems(after.to_s.split.first(4))
      return false if left.empty? || right.empty?

      present = stems(normal)
      left_hit = left.intersect?(present)
      right_hit = right.intersect?(present)
      left_hit != right_hit
    end

    # A cited step is not a pending target. Its parent item is, when the
    # question actually uses that step and there is only one such item.
    def bound_targets(text, targets)
      return targets if targets.any?

      recovered_step_item(text)
    end

    def recovered_step_item(text)
      asked = content_stems(self.class.words(text)) - self.class.question_stems
      parents = @rejections.filter_map { |row|
        next unless row["part"] == "question_about" && row["reason"].to_s == "statement_kind:step"

        step = @statements.find(row["value"])
        next unless step&.step? && asked.intersect?(content_stems(self.class.words(step.text)))

        @statements.statements.find { |item|
          item.kind == "item" && item.source == step.source && item.text == step.item
        }
      }.uniq(&:id)
      parents.one? ? [ parents.first.id ] : []
    end

    # What the question asks has to fit inside a fact. A fact mentioned inside
    # a question about something else is not a repeat. A check the technician
    # says is not done already answers whether that same check was performed.
    def repeated_fact(normal)
      open = open_check_question(normal)
      return open if open

      asked = content_stems(normal.split) - self.class.question_stems
      return nil if asked.empty?

      @facts.facts.find { |fact| question_covered_by_fact?(fact, asked) }
    end

    # :different_act is an adjustment or another act on that same subject.
    # It is not published in place of the open check.
    def open_check_question(normal)
      parsed = ReportedOperation.parse(normal)
      families = parsed.acts.reject(&:negated).map(&:family).uniq
      return nil if families.empty?

      fact = @facts.facts.find { |item| item.kind == "not_done_check" && same_check_subject?(item, parsed) }
      return nil unless fact
      return fact if families == [ "check" ]
      return :different_act if families.exclude?("check")

      nil
    end

    def same_check_subject?(fact, parsed)
      subject = ReportedOperation.parse(fact.subject.to_s).component
      subject.any? && subject.subset?(parsed.component)
    end

    # The question only restates a fact already in the case. An extra word in
    # the fact ("justo") does not keep the question: what it asks is covered.
    def question_covered_by_fact?(fact, asked)
      return false unless %w[observation done_check identity].include?(fact.kind)

      fact_core(fact).any? && asked.subset?(fact_core(fact))
    end

    def fact_core(fact)
      core_text = fact.done_check? ? [ fact.subject, fact.result ].compact.join(" ") : fact.text
      content_stems(self.class.normal(core_text).split.reject { |word| PERCEPTION.include?(word) })
    end

    def ungrounded(normal, allowed)
      normal.split.reject { |word| CONNECTORS.include?(word) || allowed.include?(self.class.stem(word)) }.uniq
    end

    def stems(text)
      text.to_s.split.map { |word| self.class.stem(word) }.to_set
    end

    def content_stems(words)
      words.reject { |word| CONNECTORS.include?(word) }.map { |word| self.class.stem(word) }.to_set
    end

    def reject(part, value, reason)
      @rejections << { "part" => part, "value" => value, "reason" => reason }
      nil
    end
  end
end
