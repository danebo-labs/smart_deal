# frozen_string_literal: true

module Rag
  # One grammar for an observation correction. Perception publishes it and the
  # reducer consumes it. The reducer does not scan the turn a second time.
  class ObservationCorrection
    FUNCTION_WORDS = %w[de del en el la los las un una es era que esta y no con por para al lo se].freeze
    TAIL = /
      (?:[,;:]|\s+y)?\s*
      \bno\s+(de|del|en|el|la|los|las|es|era)\s+([^.;!?\n]+)
    /ix
    CUE_PREFIX = /
      \A(?:corrijo(?:\s+algo\s+de\s+antes)?|correcci\p{L}*|me\s+equivoqu\p{L}*|
      en\s+realidad|le[ií]\s+mal|instead|actually)\b\s*:?\s*
    /ix

    Result = Data.define(:asserted, :retracted) do
      def active?
        asserted.any? && retracted.any?
      end
    end

    def self.none
      Result.new(asserted: [], retracted: [])
    end

    def self.resolve(turn:, observations: [], assertions: [])
      new(turn: turn, observations: observations, assertions: assertions).resolve
    end

    def self.tail?(text)
      text.to_s.match?(TAIL)
    end

    # A bare number retracts only an observation that shares a content word
    # with the replacement. A shared digit is not enough.
    def self.retracted?(observation, nucleus, asserted)
      label = normalize(observation)
      needle = normalize(nucleus)
      return false if label.blank? || needle.blank?
      return false if asserted_labels(asserted).include?(label)

      if needle.match?(/\A\d+\z/)
        word_in?(label, needle) && shared_content?(label, asserted, needle)
      else
        word_in?(label, needle)
      end
    end

    def self.normalize(value)
      FollowupQueryRewriter.normalize_label(value)
    end

    def self.asserted_labels(asserted)
      Array(asserted).map { |phrase| normalize(phrase) }
    end

    def self.word_in?(label, needle)
      label.match?(/(?<![[:alnum:]])#{Regexp.escape(needle)}(?![[:alnum:]])/)
    end

    def self.shared_content?(label, asserted, nucleus)
      content_words(asserted).any? { |word| word != nucleus && word_in?(label, word) }
    end

    def self.content_words(asserted)
      Array(asserted).flat_map { |phrase|
        normalize(phrase).split.reject { |word|
          word.length < 3 || FUNCTION_WORDS.include?(word) || word.match?(/\A\d+\z/)
        }
      }.uniq
    end

    def initialize(turn:, observations:, assertions:)
      @turn = turn.to_s
      @observations = Array(observations)
      @assertions = Array(assertions)
    end

    def resolve
      match = @turn.match(TAIL)
      return self.class.none if match.nil?

      retracted = nuclei
      asserted = asserted_phrases(match, retracted)
      return self.class.none if asserted.empty? || retracted.empty?

      Result.new(asserted: asserted, retracted: retracted)
    end

    private

    def nuclei
      @turn.scan(TAIL).filter_map { |_function, capture| nucleus(capture) }.uniq
    end

    def nucleus(capture)
      tokens = self.class.normalize(capture).split
      tokens.shift while tokens.first && FUNCTION_WORDS.include?(tokens.first)
      tokens = tokens.first(3)
      return nil if tokens.empty?

      tokens.join(" ")
    end

    def asserted_phrases(match, retracted)
      clause = clause_before(match)
      spans = (assertion_spans + observation_phrases).reject { |span|
        retracts?(span, retracted) || contained?(span, clause)
      }
      ([ clause ] + spans).compact_blank.uniq
    end

    def clause_before(match)
      before = @turn.squish[0...match.begin(0)].to_s
      before = before.split(/:\s*/).last.to_s
      before = before.sub(CUE_PREFIX, "")
      before.squish.sub(/[,;]\z/, "").presence
    end

    def observation_phrases
      @observations.filter_map { |text|
        phrase = text.to_s.squish
        next if phrase.blank? || self.class.tail?(phrase)

        phrase
      }
    end

    def assertion_spans
      @assertions.filter_map { |item|
        next unless item.is_a?(Hash)

        data = item.stringify_keys
        next if data["act"] == "negate"

        data["span"].to_s.squish.presence
      }
    end

    def retracts?(span, retracted)
      label = self.class.normalize(span)
      retracted.any? { |nucleus| label == nucleus || self.class.word_in?(label, nucleus) }
    end

    def contained?(span, clause)
      return false if clause.blank?

      inner = self.class.normalize(span)
      outer = self.class.normalize(clause)
      return false if inner.blank? || outer.blank? || inner == outer

      self.class.word_in?(outer, inner)
    end
  end
end
