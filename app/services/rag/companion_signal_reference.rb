# frozen_string_literal: true

module Rag
  # Read-only signal references use the numbered passage itself. The example
  # renderer gives the source's wiring as documentary evidence and leaves the
  # case decision with the technician until the contact is confirmed.
  module CompanionSignalReference
    SIGNAL = /\b[A-Z][A-Z0-9]{1,4}\b/
    TERMINAL = /^\s*-\s+(Serie de [^\n]+\(terminal (#{SIGNAL})\))\s*$/i
    LEVEL_RULE = /^\s*(Una serie de seguridad es "1" si [^\n]+, o "0" si [^\n]+)\.$/
    DOOR_EXAMPLE = /^\s*(Ejemplo \d+: (Puerta de cabina [^\n;+]+) \+ (Puerta de piso [^\n;]+); (contacto de traba por [^\n:]+)):\n((?:- [^\n]+\n?)+)/i
    DEFINITION_QUESTION = /\b(?:qu[eé] son|qu[eé] significa(?:n)?|qu[eé] es)\b.*\bterminal(?:es)?\b/i
    LEVEL_QUESTION = /\b(?:tensi[oó]n|voltaje)\b.*\b1\b.*\b0\b/i
    CONTACT_QUESTION = /\bqu[eé] contactos\b.*\b(?:van|entran|incluyen)\b/i

    module_function

    def resolve(question:, sources:, technician_texts: [])
      case question
      when DEFINITION_QUESTION
        definitions(question, sources)
      when LEVEL_QUESTION
        levels(question, sources)
      when CONTACT_QUESTION
        door_example(question, sources, technician_texts)
      end
    end

    def definitions(question, sources)
      requested = question.scan(SIGNAL).uniq
      return unless requested.size >= 2

      unique_reference(sources) do |body, number|
        labels = body.scan(TERMINAL).to_h { |line, name| [name, line] }
        next unless requested.all? { |name| labels.key?(name) }

        requested.map { |name| "- «#{labels.fetch(name)}» [#{number}]." }.join("\n")
      end
    end

    def levels(question, sources)
      return unless question.match?(/\bserie de seguridad\b/i)

      unique_reference(sources) do |body, number|
        line = body[LEVEL_RULE, 1]
        "«#{line}» [#{number}]." if line
      end
    end

    def door_example(question, sources, technician_texts)
      requested = question.scan(SIGNAL).uniq
      return unless requested.size >= 2

      turn = normalized_door_description(question)
      unique_reference(sources) do |body, number|
        matches = body.scan(DOOR_EXAMPLE).filter_map do |heading, cabin, landing, contact, bullets|
          next unless [cabin, landing].all? { |part| turn.include?(normalized_door_description(part)) }

          agent = contact.delete_prefix("contacto de traba por ")
          kind = FollowupQueryRewriter.normalize_label(agent)
          next unless turn.include?("traba por #{kind}") ||
            (turn.include?("traba por #{kind.split.first}") && technician_texts.any? { |text|
              FollowupQueryRewriter.normalize_label(text).include?(kind)
            })

          excerpts = bullets.lines.map { |line| line.strip.delete_prefix("- ") }
          next unless requested.all? { |name| excerpts.any? { |line| line.scan(SIGNAL).include?(name) } }

          [
            "La referencia queda condicionada a confirmar el contacto de traba.",
            "«#{heading}» [#{number}].",
            excerpts.map { |line| "- «#{line}» [#{number}]." }.join("\n"),
            "¿El contacto de traba de la puerta de piso cierra por acción del #{agent}?"
          ].join("\n\n")
        end
        matches.first if matches.one?
      end
    end

    def normalized_door_description(text)
      FollowupQueryRewriter.normalize_label(text).gsub(/\bla de piso\b/, "puerta de piso")
        .gsub(/\bes\s+/, "").squish
    end

    def unique_reference(sources)
      matches = sources.filter_map.with_index do |source, index|
        next unless CompanionTurnPublication.citable_source?(source)

        body = DocumentIdentityScope.omit_terminal_evidence_records(CompanionTurnPublication.content_of(source))
        yield body, index + 1
      end
      matches.first if matches.one?
    end
  end
end
