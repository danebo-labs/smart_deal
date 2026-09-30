# frozen_string_literal: true

module Rag
  # Splits one answer into provenance bands. No model call.
  # The first matching rule wins:
  # a [n] that exists in this turn's citations, then a phrase taken from
  # this turn's allowlisted visual observation, then Danebo guidance.
  class ProvenanceSegmenter
    MANUAL_FACT = "MANUAL_FACT"
    VISUAL_OBSERVATION = "VISUAL_OBSERVATION"
    DANEBO_GUIDANCE = "DANEBO_GUIDANCE"
    DOMINANCE_RATIO = 0.5
    VISUAL_KEYS = %w[canonical_component manufacturer model].freeze
    SENTENCE_END = /[.!?](?=\s|\z)/
    FALSE_MANUAL_LABEL = /según el manual\s*:\s*/i
    LEADING_MANUAL_LABEL = /\A\s*según el manual\b\s*:?\s*/i
    MARKER_ONLY = /\A(?:\s*\[\d+\])+\s*\z/
    PHOTO_FRAME = /
      \ben\ la\ foto\b |
      \ben\ la\ imagen\b |
      \ben\ esta\ foto\b |
      \ben\ esta\ imagen\b |
      \bla\ foto\ muestra\b |
      \bse\ observa\b |
      \bse\ observan\b |
      \bse\ ve\b |
      \bse\ ven\b
    /x

    def self.call(answer:, citations:, visual_observation: nil)
      new(answer:, citations:, visual_observation:).call
    end

    def initialize(answer:, citations:, visual_observation:)
      @answer = answer.to_s
      @citations = Array(citations)
      @visual_observation = visual_observation
      @processor = Bedrock::CitationProcessor.new
    end

    def call
      numbers = citation_numbers
      fields = observation_fields
      split_sentences(@answer).filter_map { |sentence| segment_for(sentence, numbers, fields) }
    end

    private

    def segment_for(sentence, numbers, fields)
      band = classify(sentence, numbers, fields)
      text = present_text(sentence, band)
      return nil if degenerate?(text)

      { "band" => band, "text" => text }
    end

    def classify(sentence, numbers, fields)
      return MANUAL_FACT if cited?(sentence, numbers)
      return VISUAL_OBSERVATION if visual?(sentence, fields)

      DANEBO_GUIDANCE
    end

    def cited?(sentence, numbers)
      return false if numbers.empty?

      sentence.scan(/\[(\d+)\]/).any? { |match| numbers.include?(match[0].to_i) }
    end

    def visual?(sentence, fields)
      return false if fields.empty?

      framed = PHOTO_FRAME.match?(normalize(sentence))
      tokens = significant_tokens(sentence)
      fields.any? { |value| field_evidence?(sentence, value, framed, tokens) }
    end

    # A full field phrase is not enough on its own: a brand that also lives in
    # a manual must not become a visual observation. A photo frame plus the
    # field, or a sentence that is mostly that field, is enough.
    def field_evidence?(sentence, value, framed, tokens)
      field_tokens = significant_tokens(value)
      covered = field_tokens.any? && field_tokens.all? { |token| tokens.include?(token) }
      return true if framed && (covered || phrase_present?(sentence, value))
      return false unless covered

      overlap = tokens.count { |token| field_tokens.include?(token) }
      overlap.to_f / tokens.size >= DOMINANCE_RATIO
    end

    def phrase_present?(sentence, value)
      phrase = normalize(value)
      return false if phrase.blank? || phrase == "unknown"
      return false if phrase.length < 3 && !phrase.match?(/\d/)

      normalize(sentence).match?(/(?<![[:alnum:]])#{Regexp.escape(phrase)}(?![[:alnum:]])/)
    end

    def observation_fields
      observation = FieldPhotoObservation.sanitize(@visual_observation)
      return [] if observation.nil?

      values = VISUAL_KEYS.filter_map { |key| usable_value(observation[key]) }
      values.concat(Array(observation["visible_text"]).filter_map { |item| usable_value(item) })
    end

    def usable_value(value)
      text = value.to_s.strip
      return nil if text.blank? || text.casecmp("UNKNOWN").zero?

      text
    end

    def present_text(sentence, band)
      text = @processor.strip_resolved_markers(sentence, @citations).to_s
      unless band == MANUAL_FACT
        text = text.sub(LEADING_MANUAL_LABEL, "")
        text = text.gsub(FALSE_MANUAL_LABEL, "")
      end
      text.gsub(/[ \t]{2,}/, " ").strip
    end

    def degenerate?(text)
      text.blank? || MARKER_ONLY.match?(text)
    end

    def split_sentences(answer)
      answer.split(/\r?\n/).flat_map { |line| split_line(line.strip) }.map(&:strip).reject(&:empty?)
    end

    def split_line(line)
      parts = []
      remaining = line
      while remaining.present?
        match = remaining.match(SENTENCE_END)
        unless match
          parts << remaining
          break
        end

        parts << remaining[0...match.end(0)]
        remaining = remaining[match.end(0)..].to_s.sub(/\A\s+/, "")
      end
      parts
    end

    def citation_numbers
      @citation_numbers ||= @citations.filter_map { |citation| citation_number(citation) }.to_set
    end

    def citation_number(citation)
      return nil unless citation.respond_to?(:[])

      number = Integer(citation[:number] || citation["number"], exception: false)
      number if number&.positive?
    end

    def significant_tokens(text)
      normalize(text).scan(/[a-z0-9]+/).select { |token| token.match?(/\d/) || token.length >= 4 }
    end

    def normalize(text)
      I18n.transliterate(text.to_s).downcase.gsub(/\s+/, " ").strip
    end
  end
end
