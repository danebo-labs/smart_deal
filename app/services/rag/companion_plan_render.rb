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
      notes = step_notes(steps)
      steps.group_by { |step| [ step.source, step.item ] }.each do |(source, item), group|
        lines << step_heading(item, source)
        group.each { |step| lines << "- #{quote(step)}#{notes[step.id]}." }
        warnings(group, quoted).each do |warning|
          lines << "Advertencia: #{quote(warning)}."
          quoted << warning
        end
        quoted.concat(group)
      end
      conflicts(quoted).each { |note| lines << note }
      lines << @check.question if @check.question.present?
      lines.join("\n")
    end

    private

    def link_line(fact, statement, reading)
      line = "Sobre lo que reportaste, #{case_text(fact)}: la documentación dice #{quote(statement)}"
      line += "; lectura de Danebo: #{one_fragment(reading).sub(/[.;:]\z/, '')}" if reading.present?
      "#{line}."
    end

    def step_heading(item, source)
      if applicable?(item)
        "Para este síntoma, «#{bare(item)}», la documentación indica [#{source}]:"
      else
        "Si lo que ves es «#{bare(item)}», la documentación indica para ese caso [#{source}]:"
      end
    end

    def quote(statement)
      parts = AnswerSafetyProcessor.fragments(statement.text).map { |part| bare(part) }.reject(&:empty?)
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
      covered = {}
      ordered = @facts.facts.select { |fact| %w[done_check not_done_check].include?(fact.kind) } +
                @facts.facts.select { |fact| fact.kind == "observation" }
      ordered.each do |fact|
        step = best_step(fact, steps, covered)
        next unless step

        covered[step.id] = true if fact.done_check?
        notes[step.id] << note(fact)
      end
      notes
    end

    def best_step(fact, steps, covered)
      observation = fact.kind == "observation"
      core = content_stems(observation ? fact.text : fact.subject)
      needed = observation ? [ 2, core.size ].min : 1
      scored = steps.filter_map do |step|
        next if observation && (covered[step.id] || !bare(step.text).match?(CHECK_STEP))

        overlap = (core & content_stems(step.text)).size
        [ step, overlap ] if overlap.positive? && overlap >= needed
      end
      scored.max_by { |(step, overlap)| [ overlap, -steps.index(step) ] }&.first
    end

    def note(fact)
      said = case_text(fact)
      case fact.kind
      when "done_check" then "; ya informaste: #{said}"
      when "not_done_check" then "; dijiste #{said}, así que sigue pendiente"
      else "; reportaste #{said}, que es una observación: esta comprobación no consta como hecha"
      end
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

        body = match[:body].gsub("REQUIRES_FIELD_VERIFICATION", "hay que verificarlo en campo").tr("«»“”\"", "'''''")
        "Ojo, el documento no es coherente (#{match[:id].strip}) [#{statement.source}]: #{one_fragment(body)}."
      end
    end

    def applicable?(item)
      goal = @facts.goal
      return false if goal.nil? || item.blank?

      wanted = symptom_stems(goal.text)
      offered = symptom_stems(item)
      shared = wanted & offered
      return false if wanted.empty? || offered.empty?

      shared.size >= [ 2, wanted.size ].min &&
        shared.size >= wanted.size * APPLICABLE_SHARE &&
        shared.size >= offered.size * APPLICABLE_SHARE
    end

    def symptom_stems(text)
      CompanionPlanCheck.words(text)
                        .reject { |word| SYMPTOM_STOPWORDS.include?(word) }
                        .map { |word| CompanionPlanCheck.stem(word) }
                        .reject { |stem| GENERIC_STEMS.include?(stem) }
                        .to_set
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
