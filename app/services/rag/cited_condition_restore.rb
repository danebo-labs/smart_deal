# frozen_string_literal: true

module Rag
  # The citation guard drops a paraphrase. When that sentence cited a source,
  # the source's own conditional sentence can still be quoted. The paraphrase
  # is not put back. A quote that the same citation check rejects is not used.
  class CitedConditionRestore
    CONDITION = /en caso de|si |cuando /i
    PARAMETER = /[A-Z]{2,}(?:-[A-Z0-9]+)+/

    def self.call(text:, sources:, removed:)
      new(text: text, sources: sources, removed: removed).call
    end

    def initialize(text:, sources:, removed:)
      @text = text.to_s.strip
      @sources = Array(sources)
      @removed = Array(removed)
    end

    def call
      return nil if @text.blank? || @text.match?(CompanionTurnPublication::CITATION_PATTERN)

      sentence, number = quoted_sentence
      return nil unless sentence && number

      "#{@text}\n\n«#{sentence}» [#{number}]"
    end

    private

    def quoted_sentence
      @removed.each do |item|
        body = item.is_a?(Hash) ? item["sentence"].to_s : ""
        number = body.scan(CompanionTurnPublication::CITATION_PATTERN).flatten.map(&:to_i).find(&:positive?)
        next unless number

        source = @sources[number - 1]
        next unless source && CompanionTurnPublication.citable_source?(source)

        line = matching_line(CompanionTurnPublication.content_of(source), needles(body))
        next if line.blank?
        next unless CompanionTurnPublication.verified_quote(line, [ source ])

        return [ line, number ]
      end
      nil
    end

    def matching_line(content, needles)
      return if needles.empty?

      content.to_s.lines.map { |line| line.strip.sub(/\A[-*•]\s+/, "") }.select { |line|
        plain = line.gsub("**", "")
        plain.length > 40 && plain.match?(CONDITION) && needles.any? { |token| plain.include?(token) }
      }.max_by { |line| needles.count { |token| line.gsub("**", "").include?(token) } }
    end

    def needles(sentence)
      sentence.scan(PARAMETER).uniq
    end
  end
end
