# frozen_string_literal: true

module Rag
  # The model treated a conditional instruction as already applicable.
  # The published answer keeps that condition and leaves it to confirm when
  # the technician's report does not state it and does not give the reading
  # the instruction adjusts.
  class UnconfirmedProcedure
    SATISFIED = /coincide con (?:la |esa |esta )?condici[oó]n/i
    APPLIED = /ajuste aplicable|seg[uú]n eso/i
    DROP = /coincide con (?:la |esa |esta )?condici[oó]n|ajuste aplicable|seg[uú]n eso|despu[eé]s de ajustar|el ajuste no confirma/i
    PARAMETER = /[A-Za-z]{2,}(?:[-‐‑–][A-Za-z0-9]+)+/
    READING = /(?:es(?:\s+de)?|est[aá](?:\s+en)?|=)\s*\d/i

    def self.hold(text:, sources:, technician_texts: [])
      new(text: text, sources: sources, technician_texts: technician_texts).hold
    end

    def initialize(text:, sources:, technician_texts:)
      @text = text.to_s
      @sources = Array(sources)
      @technician_texts = Array(technician_texts)
    end

    def hold
      return nil unless @text.match?(SATISFIED) && @text.match?(APPLIED)

      line, number = cited_condition
      return nil unless line && number
      return nil if condition_stated?(line) || reading_stated?(line)

      question = confirmation_question(line)
      kept = sentences.reject { |sentence| sentence.match?(DROP) }
      parts = [
        "La fuente condiciona ese ajuste a «#{line}» [#{number}].",
        "Esa condición queda por confirmar."
      ]
      parts.concat(kept)
      parts << question unless parts.any? { |part| part.match?(/[?？]\s*\z/) }
      parts.join("\n\n")
    end

    private

    def cited_condition
      @text.scan(/«([^»]+)»/).flatten.each do |quoted|
        paragraph = @text.split(/\n{2,}/).find { |piece| piece.include?("«#{quoted}»") }
        next unless paragraph

        number = citation_number(paragraph, quoted)
        next unless number

        source = @sources[number - 1]
        next unless source && CompanionTurnPublication.citable_source?(source)

        line = conditional_line(readable(CompanionTurnPublication.content_of(source)), quoted)
        return [ line, number ] if line
      end
      nil
    end

    def citation_number(paragraph, quoted)
      index = paragraph.index("«#{quoted}»")
      return unless index

      after = paragraph[(index + quoted.length + 2)..].to_s[/\A\s*\[(\d+)\]/, 1]
      return after.to_i if after

      paragraph[0...index].to_s.scan(/\[(\d+)\]/).flatten.last&.to_i
    end

    def conditional_line(content, quoted)
      needle = plain(quoted)
      content.lines.filter_map { |raw|
        body = raw.strip.sub(/\A[-*•]\s+/, "").sub(/\.\s*\z/, "")
        plain_body = plain(body)
        next unless plain_body.match?(/\Aen caso de /i)
        next unless plain_body.casecmp?(needle) || plain_body.downcase.end_with?(needle.downcase)

        body
      }.min_by(&:length)
    end

    def condition_stated?(line)
      words = plain(line.split(":", 2).first.sub(/\Aen caso de\s+/i, "")).scan(/[[:alpha:]]{3,}/)
      return false if words.empty?

      @technician_texts.any? { |text|
        body = plain(text).downcase
        words.all? { |word| body.match?(/(?<![[:alpha:]])#{Regexp.escape(word.downcase)}(?![[:alpha:]])/) }
      }
    end

    def reading_stated?(line)
      token = line.scan(PARAMETER).first
      return false if token.blank?

      pattern = /#{Regexp.escape(token)}\s*#{READING}/i
      @technician_texts.any? { |text| text.to_s.match?(pattern) }
    end

    def confirmation_question(line)
      clause = line.split(":", 2).first.sub(/\Aen caso de\s+/i, "").strip
      match = clause.match(/\A(.+?)\s+muy\s+(\p{L}+)\z/)
      return "¿El #{match[1]} es muy #{match[2]}?" if match

      "¿Se cumple «#{clause}»?"
    end

    def sentences
      @text.split(/\n+/).flat_map { |line| line.split(/(?<=[.!?])\s+/) }.map(&:strip).reject(&:empty?)
    end

    def readable(text)
      text.to_s.gsub(/\*\*(?=\S)([^*\n]+?)(?<=\S)\*\*/, '\1')
        .gsub(/\[(?:SEARCH_ALIASES|DOCUMENT|SOURCE_URI):.*?\]/m, " ")
    end

    def plain(text)
      readable(text).unicode_normalize(:nfc).gsub(/[[:space:]]+/, " ").strip
    end
  end
end
