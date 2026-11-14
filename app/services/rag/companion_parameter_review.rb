# frozen_string_literal: true

module Rag
  # Interpret a documented limit in the current job. Document and technician
  # values keep separate provenance. Only a numbered passage delivered to the
  # generator can establish the limit or give a proposed value a purpose.
  class CompanionParameterReview
    PARAMETER = CompanionCitedFloor::PARAMETER
    NUMBER = CompanionCitedFloor::NUMBER
    CONDITION = /\A\s*(?:[-*•]\s*)?((?:en caso de|em caso de|si|cuando|if|when)\b[^:]+):\s*(.+)\z/i
    READING = /\b(?:le[ií]|ley[oó]|leyeron|lectura|midi[oó]|med[ií]|marca|marcaba|muestra|mostraba|est[aá] en|qued[oó] en|indica|report[oó]|registra|reads?|measured)\b/i
    UNAVAILABLE = /\b(?:sin acceso (?:a|al)|no (?:tengo|tenemos|hay) acceso (?:a|al)|no (?:puedo|podemos) (?:leer|consultar|medir|comprobar)|can't (?:access|read|measure))\b/i
    COMMISSIONING = /commissioning|comisionamiento|comissionamento|puesta en marcha|instala[cç][iãa]o/i
    PROPOSAL = /\b(?:deje|dejar(?:lo|la)?|ponga|poner|fije|fijar|ajuste|ajustar|suba|subir|baje|bajar|set|change)\b/i
    SECTION = /\A\s*(\d+\.\d+(?:\.\d+)?)\s+/
    SUPPLEMENT = "<respuesta_complementaria>"

    Limit = Data.define(:parameter, :number, :display, :condition, :quote, :section, :heading, :source, :document)
    Reference = Data.define(:display, :section, :source, :quote)
    Review = Data.define(:kind, :limit, :reading, :reference, :pending, :supplement) do
      def prompt
        lines = [ "Dato de este caso: #{limit.parameter}. Límite condicionado de la fuente [#{limit.source}]: «#{limit.quote}»." ]
        lines << "Lectura reportada en este episodio: #{reading}." if reading
        lines << "Pregunta por la lectura actual antes de cualquier ajuste." if kind == :reading_requested
        lines << "La lectura está pendiente para Ingeniería." if kind == :reading_pending
        lines << "La propuesta es una referencia de puesta en marcha [#{reference.source}]." if reference
        if supplement
          lines << "Danebo presenta por separado la interpretación del límite. Responde solo a la otra pregunta del mensaje de este turno. " \
            "Distingue los datos de ejemplo de los datos del equipo y conserva los datos que el técnico dice que faltan. " \
            "Usa citas literales completas con [n] y escribe esa respuesta dentro de #{SUPPLEMENT} y </respuesta_complementaria>."
        end
        lines.join("\n")
      end

      def answer
        limit_note = "§#{limit.section}: «#{limit.quote}» [#{limit.source}]."
        if kind == :reading_requested
          return "#{pending.fetch('question')} Esa lectura permite compararla con el mínimo de esta rama. La causa sigue abierta.\n\n#{limit_note}"
        end
        return "#{pending.fetch('question')} Esa lectura queda pendiente. Ingeniería debe verificarla.\n\n#{limit_note}" if kind == :reading_pending

        comparison = "#{limit.parameter}: la lectura reportada de #{reading} está por debajo del mínimo de #{limit.display}."
        if reference
          return "#{reference.display} figura como referencia de puesta en marcha en §#{reference.section}: " \
            "«#{reference.quote}» [#{reference.source}]. Esa referencia no justifica ordenar el ajuste ni afirmar que resolverá el síntoma.\n\n" \
            "#{comparison} #{limit_note} La evaluación de Ingeniería sigue pendiente."
        end

        review = "#{comparison} #{limit_note} No lo reduzcas más."
        review += " La evaluación de Ingeniería queda pendiente." if kind == :reading_received
        review
      end

      def supplemental_text(raw)
        return nil unless supplement

        raw.to_s[/#{Regexp.escape(SUPPLEMENT)}\s*(.*?)\s*<\/respuesta_complementaria>/m, 1].presence
      end
    end

    class << self
      def parameter?(text)
        text.to_s.match?(/\A#{PARAMETER}\z/)
      end

      def pending_parameter(episode)
        question = episode&.pending_question
        question["about"] if question&.dig("aspect") == "parameter_reading"
      end

      def readings(text, parameter)
        parameter_label = parameter.split("-").map { |part| Regexp.escape(part) }.join("[-\\s]?")
        name = /(?<![[:alnum:]-])#{parameter_label}(?![[:alnum:]-])/i
        text.to_s.split(/(?<=[.!?])\s+|\n/).filter_map do |sentence|
          next if sentence.match?(/[?¿]/) || !sentence.match?(READING)

          match = sentence.match(/#{name}#{CompanionCitedFloor::REPORTED_GAP}/)
          [ sentence.strip, match[1] ] if match
        end
      end

      def build(question:, episode:, chunks:)
        active = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
        return if active.blank? || FollowupQueryRewriter.normalize_label(question).match?(TurnPerception::OTHER_EQUIPMENT)

        passages = Array(chunks).each_with_index.filter_map do |chunk, index|
          next if CompanionCaseRecord.gap?(chunk) || DocumentIdentityScope.reference_only_chunk?(chunk)

          metadata = chunk[:metadata].to_h.stringify_keys
          document = KbDocument.canonical_source(metadata["original_source_uri"])
          next if document.nil?

          body = DocumentIdentityScope.omit_terminal_evidence_records(CompanionCaseRecord.text_of(chunk))
          [ document, CompanionCaseRecord.number_of(chunk, index), body ]
        end
        observations = active.observations.pluck("text")
        limits = passages.flat_map { |document, source, body| limits_in(body, document, source) }
        matching = limits.filter_map do |limit|
          latest = reported(active, limit.parameter)
          current = readings(question, limit.parameter).last
          pending = pending_parameter(active)
          if latest && BigDecimal(latest.tr(",", ".")) < limit.number
            if current && BigDecimal(current.last.tr(",", ".")) == BigDecimal(latest.tr(",", "."))
              received = active.observations.any? { |row| row["text"].match?(UNAVAILABLE) } || active.excerpts.any? { |row| row["text"].match?(UNAVAILABLE) }
              Review.new(received ? :reading_received : :comparison, limit, latest, nil, nil,
                received && question.to_s.match?(/[¿?]/))
            elsif (proposal = proposed(question, limit.parameter)) &&
                (reference = reference_in(passages, limit, proposal))
              Review.new(:proposed_reference, limit, latest, reference, nil, false)
            end
          elsif latest.nil? && (pending.nil? || pending == limit.parameter) && !question.to_s.match?(/[¿?]/)
            if access_unavailable?(question, observations)
              reading_review(limit, :reading_pending)
            elsif opened_with_matching_symptom?(active, question, limit)
              reading_review(limit, :reading_requested)
            end
          end
        end
        matching.one? ? matching.first : nil
      end

      private

      def reading_review(limit, kind)
        target = { "item" => limit.parameter, "document_key" => limit.document.join("/") }
        question = "¿Cuál es la lectura actual de #{limit.parameter}?"
        if kind == :reading_requested && limit.heading.match?(/menu pid/i)
          question = "¿Cuál es la lectura actual de #{limit.parameter} en el menú PID?"
        end
        state = {
          "type" => "documented_context", "aspect" => "parameter_reading", "about" => limit.parameter,
          "question" => question, "targets" => [ target ]
        }
        Review.new(kind, limit, nil, nil, state, false)
      end

      def opened_with_matching_symptom?(episode, question, limit)
        goal = episode.goal
        return false unless goal&.dig("correlation_id").present? && goal["correlation_id"] == episode.opened_by

        symptom = FollowupQueryRewriter.normalize_label(goal["text"])
        return false if symptom.blank? || !FollowupQueryRewriter.normalize_label(question).include?(symptom)

        words = symptom.scan(/\b[[:alpha:]]{4,}\b/).uniq
        documented = FollowupQueryRewriter.normalize_label("#{limit.heading} #{limit.condition}").split
        (words & documented).size >= 2
      end

      def access_unavailable?(question, observations)
        question.to_s.match?(UNAVAILABLE) && observations.any? { |text| !text.match?(UNAVAILABLE) }
      end

      def reported(episode, parameter)
        observations = episode.observations.pluck("text")
        checks = episode.checks.reverse.find do |row|
          row["status"] == "done" && row["subject"].casecmp?(parameter) && row["result"].to_s.match?(/\A#{NUMBER}\z/)
        end
        observations.reverse_each do |text|
          reading = readings(text, parameter).last
          return reading.last if reading
        end
        checks&.dig("result")
      end

      def limits_in(body, document, source)
        section = nil
        heading = nil
        body.lines.filter_map do |line|
          if (number = line[SECTION, 1])
            section = number
            heading = line.strip
          end
          match = line.strip.match(CONDITION)
          next unless section && match

          action = match[2]
          names = action.scan(PARAMETER).uniq
          display = action[CompanionCitedFloor::MINIMUM, 1]
          next unless names.one? && display && action.match?(CompanionCitedFloor::SOURCE_DECREASE)

          quote = line.strip.sub(/\A[-*•]\s*/, "").delete_suffix(".").gsub("**", "")
          Limit.new(names.first, BigDecimal(display.tr(",", ".")), display, match[1], quote, section, heading, source, document)
        end
      end

      def proposed(question, parameter)
        return nil unless question.to_s.match?(PROPOSAL) && question.to_s.match?(/[¿?]/)

        named = question.to_s.scan(PARAMETER).uniq
        return nil if named.any? && named != [ parameter ]

        values = question.to_s.scan(NUMBER)
        values.sole if values.one?
      end

      def reference_in(passages, limit, proposal)
        references = passages.flat_map do |document, source, body|
          next [] unless document == limit.document && body.match?(COMMISSIONING)

          section = nil
          lead = nil
          body.lines.filter_map do |line|
            if (heading = line[SECTION, 1])
              section = heading
              lead = line.strip
            end
            display = line[/\A\s*[-*•]?\s*"#{Regexp.escape(limit.parameter)}"\s*=\s*\[(#{NUMBER})\]/, 1]
            next unless display && section && BigDecimal(display.tr(",", ".")) == BigDecimal(proposal.tr(",", "."))

            Reference.new(display, section, source, lead)
          end
        end
        references.uniq { |row| [ row.display, row.section, row.quote ] }.then { |rows| rows.sole if rows.one? }
      end
    end
  end
end
