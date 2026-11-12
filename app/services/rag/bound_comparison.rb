# frozen_string_literal: true

module Rag
  # «Tu valor, 2,5, está por debajo de ese mínimo documentado»: a sentence
  # without [n] that compares what the technician reported with a limit that a
  # kept sentence of the same answer quotes with its own [n]. Its numbers are
  # the technician's or the quoted limit's, it has a comparator and no order,
  # and nothing in it is foreign to the sources. It restates nothing the manual
  # did not say, so it is not an uncited attribution. Claim backing and
  # publication ask the same question.
  class BoundComparison
    COMPARATOR = /por\s+debajo|debajo\s+de|inferior|menor|por\s+encima|superior|mayor|supera|excede|ya\s+(?:est[aá]s?|eres?|es)\s+(?:en\s+)?(?:el\s+)?(?:m[ií]nimo|l[ií]mite)/i.freeze
    LIMIT_REFERENCE = /(?<![[:alnum:]])(?:ese|dicho|este|el|del)\s+(?:m[ií]nimo|l[ií]mite)/i.freeze
    LIMIT_WORD = /m[ií]nimo|l[ií]mite/i.freeze
    NUMBER = CompanionCitedFloor::NUMBER

    def self.call(...)
      new(...).call
    end

    # quotes: literal quotes of kept, cited sentences of the same answer.
    def initialize(sentence:, quotes:, technician_texts:, sources:)
      @sentence = sentence.to_s
      @quotes = Array(quotes)
      @technician_texts = Array(technician_texts)
      @sources = Array(sources)
    end

    def call
      return false if @quotes.empty? || !@sentence.match?(COMPARATOR) || order?

      numbers = @sentence.scan(NUMBER)
      reported = @technician_texts.flat_map { |text| text.to_s.scan(NUMBER) }
      quoted = @quotes.flat_map { |text| text.scan(NUMBER) }
      return false if numbers.empty? || numbers.none? { |number| reported.include?(number) }
      return false unless numbers.all? { |number| reported.include?(number) || quoted.include?(number) }
      return false unless numbers.any? { |number| quoted.include?(number) } ||
        (@sentence.match?(LIMIT_REFERENCE) && @quotes.any? { |text| text.match?(LIMIT_WORD) })

      !foreign_tokens?
    end

    private

    # An unnegated decrease or set verb. «no hay respaldo para bajarlo» is not one.
    def order?
      [ CompanionCitedFloor::DECREASE, CompanionCitedFloor::SET_UP ].any? do |pattern|
        @sentence.to_enum(:scan, pattern).any? do
          !@sentence[0...Regexp.last_match.begin(0)].match?(CompanionCitedFloor::NEGATOR)
        end
      end
    end

    def foreign_tokens?
      bodies = @sources.flat_map { |source| [ CompanionTurnPublication.content_of(source), source["document"].to_s ] } +
        @technician_texts.map(&:to_s)
      labels = @sentence.scan(CompanionPlanEvidence::LABEL_TOKEN).select { |token| token.length >= CompanionPlanEvidence::MIN_LABEL_CHARS }
      (CompanionTurnPublication.claim_tokens(@sentence) + labels).uniq.any? do |token|
        bodies.none? { |body| body.include?(token) }
      end
    end
  end
end
