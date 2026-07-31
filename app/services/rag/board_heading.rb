# frozen_string_literal: true

module Rag
  # The board a chunk declares in its own "## " heading, plus the question-side
  # test for whether the technician already named that board.
  #
  # The heading comes straight from the page, so it can never name a board that
  # is not there — unlike a metadata fallback. Extracted verbatim from
  # Rag::AmbiguousModelResponder (its only consumer until the structured route
  # needed the same board identity for Rag::FamilyAmbiguityDetector).
  module BoardHeading
    HEADING_PREFIX = /\A##\s+/.freeze
    SECTION_PREFIX = /\A(?:S\d+\s+[—–-]\s+)?(?:DIAGRAM|SAFETY SYSTEM):\s*/i.freeze
    DESCRIPTION_SPLIT = /\s+[—–]\s+(?=(?:Diagrama|Esquema|Conex|Seguridad|Cadena)\b)/i.freeze
    MAX_LABEL_CHARS = 80

    # Words this short ("III", "TW", "LX") share no prefix worth trusting, so
    # they must match a question word exactly.
    SHORT_WORD_CHARS = 3
    # "BÁSICO" ~ "básica", "ELECTRICO" ~ "eléctrica": gender and plural variants
    # of the same board word still agree on their first four characters.
    MIN_COMMON_PREFIX = 4

    module_function

    def label(content)
      heading = content.to_s.lines.find { |line| line.match?(HEADING_PREFIX) }
      return if heading.blank?

      label = heading
        .sub(HEADING_PREFIX, "")
        .sub(SECTION_PREFIX, "")
        .split(DESCRIPTION_SPLIT, 2)
        .first
        .split(%r{\s+/\s+}, 2)
        .first
        .strip
      return if label.blank? || label.casecmp?("PIPELINE_INJECTED")

      label.first(MAX_LABEL_CHARS)
    end

    # True when the question already names the board a heading declares.
    #
    # Only the heading's identifier-shaped tokens are required: a real heading
    # mixes the board name with free descriptive prose ("ARCA II Safety Chain &
    # Connector Layout", "Tabla de LEDs de la cadena serie — MICONIC LX"), so
    # demanding every prose word would report every board as unnamed.
    def mentioned?(heading, question)
      tokens = board_tokens(heading)
      return false if tokens.empty?

      asked = words(question)
      return false if asked.empty?

      tokens.all? { |token| asked.any? { |word| word_match?(token, word) } }
    end

    def board_tokens(heading)
      identifiers = Rag::QueryEntities.identifiers(heading.to_s).map { |identifier| fold(identifier.raw) }
      (identifiers.presence || words(heading)).uniq
    end
    private_class_method :board_tokens

    def words(text)
      fold(text).scan(/[[:alnum:]]+/)
    end
    private_class_method :words

    def word_match?(token, word)
      return true if token == word
      return false if token.length <= SHORT_WORD_CHARS

      common_prefix_length(token, word) >= MIN_COMMON_PREFIX
    end
    private_class_method :word_match?

    def common_prefix_length(left, right)
      limit = [ left.length, right.length ].min
      (0...limit).each { |index| return index if left[index] != right[index] }
      limit
    end
    private_class_method :common_prefix_length

    def fold(text)
      text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").upcase
    rescue StandardError
      text.to_s.upcase
    end
    private_class_method :fold
  end
end
