# frozen_string_literal: true

module Rag
  # Spanish text for a checked companion plan. A documentary statement is
  # quoted whole, fragment by fragment, with its source number in the same
  # fragment, so a condition inside it stays with it. A step of another
  # symptom is introduced as that symptom. A case note on a step repeats
  # what the technician said; it never turns an observation into a check.
  # A warning of the same item or section, and a conflict note of a quoted
  # source, travel with what was quoted.
  class CompanionPlanRender
    APPLICABLE_SHARE = 0.6
    GENERIC_STEMS = %w[puert compr verif revis senal model opera estad].to_set.freeze
    SYMPTOM_STOPWORDS = %w[el la los las un una unos unas lo de del se a al en y e o u que con por].to_set.freeze
    CHECK_STEP = /\A(?:comprob|verific|revis|asegur|control|observ|mir)/i
    NOTE_MARKER = /\[CONFLICTO_DOCUMENTAL\s+(?<id>[^:\]]+):\s*(?<body>.*)\]\z/m

    def self.call(check, facts:, statements:)
      new(check, facts, statements).call
    end

    def self.applicable?(item, facts)
      goal = facts.respond_to?(:goal) ? facts.goal : nil
      return false if goal.nil? || item.blank?

      wanted = symptom_stems(goal.text)
      offered = symptom_stems(item)
      shared = wanted & offered
      return false if wanted.empty? || offered.empty?

      shared.size >= [ 2, wanted.size ].min &&
        shared.size >= wanted.size * APPLICABLE_SHARE &&
        shared.size >= offered.size * APPLICABLE_SHARE
    end

    def self.symptom_stems(text)
      CompanionPlanCheck.words(text)
                        .reject { |word| SYMPTOM_STOPWORDS.include?(word) }
                        .map { |word| CompanionPlanCheck.stem(word) }
                        .reject { |stem| GENERIC_STEMS.include?(stem) }
                        .to_set
    end

    def initialize(check, facts, statements)
      @check = check
      @facts = facts
      @statements = statements
    end

    def call
      lines = []
      quoted = []
      @check.links.each do |link|
        statement = @statements.find(link[:statement])
        next if link[:reading].blank? && @check.steps.include?(statement.id)

        lines << link_line(@facts.find(link[:fact]), statement, link[:reading])
        quoted << statement
      end
      steps = @check.steps.map { |id| @statements.find(id) }
      notes, relations, noted = step_notes(steps)
      steps.group_by { |step| [ step.source, step.item ] }.each do |(source, item), group|
        lines << step_heading(item, source)
        group.each do |step|
          body = relations[step.id] == :partial ? operation_sentences(step.text) : step.text
          lines << "- #{quote(step, body)}#{notes[step.id]}."
        end
        warnings(group, quoted).each do |warning|
          lines << "Advertencia: #{quote(warning)}."
          quoted << warning
        end
        quoted.concat(group)
      end
      association_lines.each { |line| lines << line }
      limit_lines.each { |line| lines << line }
      omission_lines.each { |line| lines << line }
      unmatched_reports(noted).each { |fact| lines << "También informaste: #{case_text(fact)}." }
      conflicts(quoted).each { |note| lines << note }
      question_lines.each { |line| lines << line }
      lines.join("\n")
    end

    private

    def link_line(fact, statement, reading)
      line = "Sobre lo que reportaste, #{case_text(fact)}: la documentación dice #{quote(statement)}"
      line += "; lectura de Danebo: #{one_fragment(reading).sub(/[.;:]\z/, '')}" if reading.present?
      "#{line}."
    end

    def step_heading(item, source)
      confirmed = confirmed_for(item)
      if confirmed.present? && confirmed != "goal"
        fact = @facts.find(confirmed)
        "Para lo que informaste, #{case_text(fact)}, la documentación indica en «#{bare(item)}» [#{source}]:"
      else
        "Para este síntoma, «#{bare(item)}», la documentación indica [#{source}]:"
      end
    end

    def confirmed_for(item)
      confirmed = @check.respond_to?(:confirmed_items) ? @check.confirmed_items : nil
      confirmed.is_a?(Hash) ? confirmed[item.to_s] : nil
    end

    def association_lines
      rows = @check.respond_to?(:associations) ? Array(@check.associations) : []
      rows.filter_map { |row|
        next unless row[:relation] == :incompatible || row["relation"].to_s == "incompatible"

        item = row[:item] || row["item"]
        fact = @facts.find(row[:fact] || row["fact"])
        source = row[:source] || row["source"]
        next if item.blank? || fact.nil? || source.blank?

        "La documentación trata aparte «#{bare(item)}» [#{source}]; lo que informaste, #{case_text(fact)}, no coincide con esa condición, así que esa indicación no se aplica aquí."
      }
    end

    def limit_lines
      rows = @check.respond_to?(:limits) ? Array(@check.limits) : []
      rows.filter_map { |row|
        item = row["item"] || row[:item]
        source = row["source"] || row[:source]
        next if item.blank? || source.blank?

        "Indicaste que no puedes distinguirlo; la indicación de «#{bare(item)}» [#{source}] depende de ese dato."
      }
    end

    def omission_lines
      rows = @check.respond_to?(:omissions) ? Array(@check.omissions) : []
      rows.filter_map { |row|
        item = row["item"] || row[:item]
        next if item.blank?

        "Tu respuesta apunta a «#{bare(item)}», pero ese apartado no está en la documentación cargada en este turno."
      }
    end

    def question_lines
      return [] if @check.question.blank?

      lines = []
      targets = question_statements
      if targets.one?
        lines << "Para orientar falta un dato: la documentación trata «#{bare(targets.first.text)}» [#{targets.first.source}]."
      elsif targets.size == 2
        left, right = targets
        lines << "Para orientar falta distinguir: la documentación trata por separado «#{bare(left.text)}» [#{left.source}] y «#{bare(right.text)}» [#{right.source}]."
      end
      lines << @check.question
      lines
    end

    def question_statements
      ids = @check.respond_to?(:question_targets) ? Array(@check.question_targets) : []
      ids.filter_map { |id| @statements.find(id) }.first(2)
    end

    def quote(statement, text = statement.text)
      parts = AnswerSafetyProcessor.fragments(text).map { |part| bare(part) }.reject(&:empty?)
      body = if parts.any? { |part| part.match?(/[«»]/) }
        parts.join("; ")
      else
        parts.map { |part| "«#{part}»" }.join("; ")
      end
      "#{body} [#{statement.source}]"
    end

    def case_text(fact)
      fact.literal || %w[goal identity observation].include?(fact.kind) ? "«#{bare(fact.text)}»" : "(#{bare(fact.text)})"
    end

    def step_notes(steps)
      notes = Hash.new { |hash, key| hash[key] = +"" }
      relations = {}
      noted = []
      covered = {}
      ordered = @facts.facts.select { |fact| %w[done_check not_done_check].include?(fact.kind) } +
                @facts.facts.select { |fact| fact.kind == "observation" }
      ordered.each do |fact|
        step, relation = best_step(fact, steps, covered)
        next unless step

        covered[step.id] = true if fact.done_check?
        relations[step.id] = relation if relation
        noted << fact.id
        notes[step.id] << note(fact, relation)
      end
      [ notes, relations, noted ]
    end

    def best_step(fact, steps, covered)
      return observation_step(fact, steps, covered) if fact.kind == "observation"

      wanted = fact.done_check? ? :complete : :pending
      ranked = steps.filter_map do |step|
        relation = ReportedOperation.correspondence(
          report_text: fact.text, result: fact.result,
          status: fact.done_check? ? "done" : "not_done",
          statement_text: step.text
        )
        score = if relation == wanted then 2
        elsif fact.done_check? && relation == :partial then 1
        end
        [ step, relation, score ] if score
      end
      chosen = ranked.max_by { |step, _relation, score| [ score, -steps.index(step) ] }
      chosen ? [ chosen[0], chosen[1] ] : [ nil, nil ]
    end

    def observation_step(fact, steps, covered)
      fact_stems = CompanionPlanCheck.words(fact.text).map { |word| CompanionPlanCheck.stem(word) }.to_set
      core = content_stems(fact.text)
      needed = [ 2, core.size ].min
      scored = steps.filter_map do |step|
        next if covered[step.id] || !bare(step.text).match?(CHECK_STEP)

        anchor = CompanionCaseRelation.first_anchor_stem(step.text)
        next if anchor.nil? || fact_stems.exclude?(anchor)

        overlap = (core & content_stems(step.text)).size
        [ step, overlap ] if overlap.positive? && overlap >= needed
      end
      step = scored.max_by { |(item, overlap)| [ overlap, -steps.index(item) ] }&.first
      [ step, nil ]
    end

    def note(fact, relation = nil)
      said = case_text(fact)
      case fact.kind
      when "done_check"
        if relation == :partial
          "; informaste #{said}, que no completa esta operación"
        else
          "; ya informaste: #{said}"
        end
      when "not_done_check" then "; dijiste #{said}, así que sigue pendiente"
      else "; reportaste #{said}, que es una observación: esta comprobación no consta como hecha"
      end
    end

    # A partial report quotes the sentences that carry the operation. A later
    # sentence with no act is the document's conditional result and is not applied.
    def operation_sentences(text)
      sentences = text.to_s.split(CompanionStatements::SENTENCE_SPLIT).map(&:strip).reject(&:empty?)
      kept = sentences.select { |sentence| ReportedOperation.parse(sentence).acts.reject(&:negated).any? }
      kept.any? ? kept.join(" ") : text
    end

    def unmatched_reports(noted)
      linked = @check.links.pluck(:fact).to_set
      @facts.facts.select { |fact| fact.done_check? && noted.exclude?(fact.id) && linked.exclude?(fact.id) }
    end

    def warnings(group, quoted)
      ids = (group + quoted).map(&:id)
      @statements.statements.select do |statement|
        statement.kind == "warning" && ids.exclude?(statement.id) &&
          group.any? { |step| step.source == statement.source && (same?(step.item, statement.item) || same?(step.section, statement.section)) }
      end
    end

    def conflicts(quoted)
      sources = quoted.map(&:source).uniq
      @statements.statements.filter_map do |statement|
        next unless statement.kind == "conflict" && sources.include?(statement.source)

        match = statement.text.match(NOTE_MARKER)
        next unless match

        body = match[:body].gsub(CompanionStatements::EXTRACTION_MARKER, "").gsub(/\s{2,}/, " ").strip
        body = body.tr("«»“”\"", "'''''")
        "Ojo, el documento no es coherente (#{match[:id].strip}) [#{statement.source}]: #{one_fragment(body)}."
      end
    end

    def applicable?(item)
      self.class.applicable?(item, @facts)
    end

    def content_stems(text)
      CompanionPlanCheck.words(text)
                        .reject { |word| CompanionPlanCheck::CONNECTORS.include?(word) || CompanionPlanCheck::PERCEPTION.include?(word) }
                        .map { |word| CompanionPlanCheck.stem(word) }
                        .reject { |stem| GENERIC_STEMS.include?(stem) }
                        .to_set
    end

    def same?(left, right)
      left.present? && left == right
    end

    def one_fragment(text)
      AnswerSafetyProcessor.fragments(text.to_s).map { |part| part.sub(/[.;:]\z/, "") }.join("; ")
    end

    def bare(text)
      text.to_s.squish.sub(/\A[•●▪–—-]\s*/, "").sub(/[.;:]+\z/, "")
    end
  end
end
