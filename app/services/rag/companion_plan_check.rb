# frozen_string_literal: true

module Rag
  # Deterministic check of one companion plan. A link joins a case fact to a
  # source statement; its reading may only use words of that statement, of
  # the case, and connectives. A step must be a step statement. The question
  # must use words of the sources or the case and must not ask what the case
  # already says. An invalid part is dropped with its reason; the rest stays.
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
    OPERATION = /\b(?:ajust|gir|rot|aument|reduc|sub|baj|calibr|regul|cambi|reemplaz|sustitu|puente|desconect|conect|med|mid|puls|presion|apret|limpi|muev|mov|forz|reinici|reset)(?:ar|er|ir|a|e|i|as|es|alo|elo|arlo|erlo|irlo|ando|iendo|ala|ela)\b/
    STATUS = /\b(?:comprob|verific|revis|confirm|cheque|prob|realiz)(?:ad[oa]s?|aste|aron|amos|o|e)\b|\bya (?:lo )?(?:hiciste|hizo|hice)\b/

    Result = Data.define(:links, :steps, :question, :rejections) do
      def usable?
        links.any? || steps.any?
      end

      def to_h
        {
          "links" => links.map { |link| link.transform_keys(&:to_s) },
          "steps" => steps,
          "question" => question,
          "rejections" => rejections
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
      links = check_links
      candidates = candidate_steps
      text = @plan["question"].to_s.squish
      provisional = text.present? && question_reason(text, candidates).nil? ? text : nil
      steps = []
      candidates.each do |id|
        if keep_step?(id, links, provisional)
          steps << id
        else
          reject("step", id, "other_case_without_question")
        end
      end
      final_reason = text.present? ? question_reason(text, steps) : nil
      question = text.present? && final_reason.nil? ? text : nil
      if text.present? && question.nil?
        reject("question", text, final_reason || question_reason(text, candidates) || "invalid")
        steps.reject! do |id|
          next false if step_grounded?(id, links)

          reject("step", id, "other_case_without_question")
          true
        end
      end
      Result.new(links: links, steps: steps, question: question, rejections: @rejections)
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
        reason ||= reading_reason(reading, fact, statement) if reading.present?
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

    # A step of another item stays when the case already names what distinguishes
    # that item, when a fact is linked to a statement of that item, or when the
    # question itself names that distinction. Any other question does not import
    # the other item's actions.
    def keep_step?(id, links, question)
      step_grounded?(id, links) || distinguishing_question?(question, @statements.find(id)&.item)
    end

    def step_grounded?(id, links)
      statement = @statements.find(id)
      return false unless statement

      item_applicable?(statement.item) || case_distinguishes?(statement.item) || linked_to_item?(statement, links)
    end

    def item_applicable?(item)
      CompanionPlanRender.applicable?(item, @facts)
    end

    def case_distinguishes?(item)
      distinctive = distinctive_stems(item)
      return false if distinctive.empty?

      @facts.facts.any? do |fact|
        next false if fact.kind == "goal"

        distinctive.intersect?(content_stems(self.class.normal(fact.text).split))
      end
    end

    def linked_to_item?(statement, links)
      item = statement.item.to_s
      return false if item.blank?

      links.any? do |link|
        other = @statements.find(link[:statement])
        other && (other.item == item || (other.kind == "item" && other.text == item))
      end
    end

    def distinguishing_question?(question, item)
      return false if question.blank?

      distinctive = distinctive_stems(item)
      return false if distinctive.empty?

      asked = content_stems(self.class.normal(question).split)
      asked -= QUESTION_WORDS.map { |word| self.class.stem(word) }.to_set
      distinctive.intersect?(asked)
    end

    def distinctive_stems(item)
      CompanionPlanRender.distinctive_stems(item, @facts.goal&.text)
    end

    def check_fact?(fact)
      fact.done_check? || fact.kind == "not_done_check"
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

      normal = self.class.normal(text)
      sources = self.class.normal(@statements.statements.map { |item| [ item.text, item.item ].compact.join(" ") }.join(" "))
      case_text = self.class.normal((@facts.facts.map(&:text) + @turns).join(" "))
      return "exclusion" if normal.match?(EXCLUSION)
      return "prescription" if normal.match?(PRESCRIPTION)

      step_text = self.class.normal(steps.map { |id| @statements.find(id).text }.join(" "))
      return "operation" if normal.match?(OPERATION) && !operation_in?(normal, step_text)

      allowed = stems(sources) | stems(case_text) | QUESTION_WORDS.map { |word| self.class.stem(word) }.to_set
      missing = ungrounded(normal, allowed)
      return "ungrounded:#{missing.first(3).join(',')}" if missing.any?

      repeated = repeated_fact(normal)
      return "repeats_fact:#{repeated.id}" if repeated

      nil
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

    def repeated_fact(normal)
      present = stems(normal)
      found = @facts.facts.find { |fact| fact_covered_by_question?(fact, present) }
      return found if found

      asked = content_stems(normal.split) - self.class.question_stems
      return nil if asked.empty?

      @facts.facts.find { |fact| question_covered_by_fact?(fact, asked) }
    end

    def fact_covered_by_question?(fact, present)
      return false unless %w[observation done_check identity].include?(fact.kind)

      core = fact_core(fact)
      core.any? && core.subset?(present)
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
