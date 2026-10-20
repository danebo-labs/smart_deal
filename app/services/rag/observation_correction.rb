# frozen_string_literal: true

module Rag
  # One grammar for an observation correction. Perception publishes it and the
  # reducer consumes it. The reducer does not scan the turn a second time.
  class ObservationCorrection
    FUNCTION_WORDS = %w[de del en el la los las un una es era que esta y no con por para al lo se].freeze
    # The separator is required. "pero no la termina de cerrar" and "el motor
    # no es el que hace ruido" are reports, not a retraction.
    TAIL = /
      (?:[,;:]\s*|\s+y\s+)
      no\s+(de|del|en|el|la|los|las|es|era)\s+([^.;!?\n]+)
    /ix
    # A bare state is one word and then the sentence ends. "no apagado."
    # "no Chapa nivel 2" and "no Tablero norte" stay identifier contrasts.
    BARE_STATE = /
      (?:[,;:]\s*|\s+y\s+)
      no\s+(\p{L}{3,})
      (?=\s*[.;!?]|\s*\z)
    /ix
    CUE_PREFIX = /
      \A(?:corrijo(?:\s+algo\s+de\s+antes)?|correcci\p{L}*|me\s+equivoqu\p{L}*|
      en\s+realidad|le[ií]\s+mal|instead|actually)\b\s*:?\s*
    /ix
    CUE = /
      \b(?:corrijo|correcci\p{L}*|me\s+equivoqu\p{L}*|en\s+realidad|le[ií]\s+mal|instead|actually)\b
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

    # Stored observations the retraction can replace. One match is that
    # observation. Several matches stay one observation when the replacement
    # shares a content word with exactly one of them. Several matches and no
    # such word are ambiguous: the caller asks which datum changed.
    def self.targets(observations, correction)
      return [] unless correction&.active?

      texts = Array(observations).filter_map { |item|
        text = item.is_a?(Hash) ? item["text"].to_s : item.to_s
        text.presence
      }
      matches = texts.select { |text|
        correction.retracted.any? { |nucleus| retracted?(text, nucleus, correction.asserted) }
      }
      return matches if matches.size <= 1

      words = content_words(correction.asserted)
      selected = matches.select { |text|
        label = normalize(text)
        words.any? { |word|
          word_in?(label, word) && matches.one? { |other| word_in?(normalize(other), word) }
        }
      }
      return :ambiguous unless selected.one?

      selected
    end

    def initialize(turn:, observations:, assertions:)
      @turn = turn.to_s
      @observations = Array(observations)
      @assertions = Array(assertions)
    end

    def resolve
      bare = bare_state
      return bare if bare

      match = @turn.match(TAIL)
      return self.class.none if match.nil?

      clause = clause_before(match)
      retracted = nuclei(clause)
      return self.class.none if retracted.empty?

      asserted = asserted_phrases(clause, retracted)
      return self.class.none if asserted.empty?

      Result.new(asserted: asserted, retracted: retracted)
    end

    private

    def bare_state
      match = @turn.match(BARE_STATE)
      return nil if match.nil? || !@turn.match?(CUE)

      value = nucleus(match[1])
      return nil if value.blank?

      clause = clause_before(match)
      retracted = [ value ]
      asserted = asserted_phrases(clause, retracted)
      return nil if asserted.empty?

      self.class::Result.new(asserted: asserted, retracted: retracted)
    end

    def nuclei(clause)
      cue = @turn.match?(CUE)
      @turn.scan(TAIL).filter_map { |_function, capture|
        value = nucleus(capture)
        value if value && (cue || parallel?(value, clause))
      }.uniq
    end

    # Without an explicit cue, the retracted value must contrast with the
    # asserted one: the same head word ("planta 2, no de planta 1") or a
    # number against a number ("es el 5, no el 7").
    def parallel?(value, clause)
      return false if clause.blank?

      label = self.class.normalize(clause)
      head = value.split.find { |word| word.length >= 3 && FUNCTION_WORDS.exclude?(word) && !word.match?(/\A\d+\z/) }
      return self.class.word_in?(label, head) if head

      value.match?(/\A\d+\z/) && label.match?(/(?<![[:alnum:]])\d+(?![[:alnum:]])/)
    end

    def nucleus(capture)
      tokens = self.class.normalize(capture).split
      tokens.shift while tokens.first && FUNCTION_WORDS.include?(tokens.first)
      tokens = tokens.first(3)
      return nil if tokens.empty?

      tokens.join(" ")
    end

    def asserted_phrases(clause, retracted)
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
