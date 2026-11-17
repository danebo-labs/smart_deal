# frozen_string_literal: true

module Rag
  # A citation that quotes only the instruction of a conditional line is the
  # same line with its condition restored. The citation number stays. A quote
  # that already opens on the condition is left as written.
  class ConditionalQuote
    OPENING = /\Aen caso de /i

    def self.complete(text:, sources:)
      new(text: text, sources: sources).complete
    end

    def initialize(text:, sources:)
      @text = text.to_s
      @sources = Array(sources)
    end

    def complete
      return @text if @text.blank?

      @text.split(/(\n+)/).map { |piece| piece.include?("\n") ? piece : complete_paragraph(piece) }.join
    end

    private

    def complete_paragraph(paragraph)
      paragraph.gsub(/«([^»]+)»/) do
        quoted = Regexp.last_match(1)
        line = restored_line(quoted, paragraph)
        line ? "«#{plain(line)}»" : Regexp.last_match(0)
      end
    end

    def restored_line(quoted, paragraph)
      needle = plain(quoted)
      return if needle.length < 20 || needle.match?(OPENING)

      number = citation_number(paragraph, quoted)
      return unless number

      source = @sources[number - 1]
      return unless source && CompanionTurnPublication.citable_source?(source)

      conditional_line(readable(CompanionTurnPublication.content_of(source)), needle)
    end

    def citation_number(paragraph, quoted)
      index = paragraph.index("«#{quoted}»")
      return unless index

      after = paragraph[(index + quoted.length + 2)..].to_s[/\A\s*\[(\d+)\]/, 1]
      return after.to_i if after

      before = paragraph[0...index].to_s.scan(/\[(\d+)\]/).flatten.last
      before&.to_i
    end

    def conditional_line(content, needle)
      content.lines.filter_map { |raw|
        body = raw.strip.sub(/\A[-*•]\s+/, "").sub(/\.\s*\z/, "")
        plain_body = plain(body)
        next unless plain_body.match?(OPENING)
        next unless plain_body.length > needle.length
        next unless plain_body.downcase.end_with?(needle.downcase)

        body
      }.min_by(&:length)
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
