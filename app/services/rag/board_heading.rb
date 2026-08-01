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
    # A parenthetical on a "## " heading is a footnote ("ARCA III (Orona PDCM
    # 5124537)"), not part of the board's name — left in, its extra tokens (the
    # PDCM reference number) block `mentioned?` from ever matching. Stripped only
    # for tokenizing; `label` itself keeps the parenthetical verbatim.
    PARENTHETICAL = /\([^)]*\)/.freeze

    # Descriptive/structural words a heading or a "**Section:**" line adds
    # around the actual board name — never part of what identifies a board, so
    # they must never gate a match nor count toward "is this heading generic".
    STOP = %w[DE DEL LA EL LOS LAS UN UNA Y O EN CON PARA POR A AND OR OF THE TO IN ON FOR
              PLACA PLACAS TABLA TABLAS SERIE SERIES LED LEDS DIAGRAMA DIAGRAMAS DIAGRAM
              PAGINA PAGE VISIBLE VISIBLES ESTADO ESTADOS STATUS INDICATOR INDICATORS
              OVERVIEW LAYOUT WIRING CONNECTOR CONNECTORS CONEXIONADO IDENTIFICACION
              PRINCIPAL PRINCIPALES SAFETY CHAIN TERMINAL BOARD ELECTRICAL SEGURIDAD
              SEGURIDADES ENTRADA ENTRADAS CADENA ESQUEMA BORNA BORNAS CONECTOR CONECTORES
              SISTEMA SISTEMAS].to_set.freeze
    SECTION_PREFIX_LINE = /\A\s*S\d+\s*[—–\-]\s*[A-ZÁÉÍÓÚ \/]+:\s*/i.freeze
    SECTION_TOKEN       = /\AS\d+\z/.freeze

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

    # The board name a generic "## " table heading hides behind its own
    # "**Section:**" line (Rag::EvidenceCandidateSelector::SECTION_MARKER), e.g.
    # a page headed "## LEDs de Estado — Tabla de Series" whose
    # "**Section:** S7 — DIAGRAM: ARCA BASICO — ..." line carries the actual
    # board. Reuses `label`'s own transform via a synthetic "## " line so the
    # two never drift apart.
    def section_label(content)
      line = content.to_s.lines.find { |candidate| candidate.strip.start_with?(Rag::EvidenceCandidateSelector::SECTION_MARKER) }
      return if line.blank?

      text = line.strip.delete_prefix(Rag::EvidenceCandidateSelector::SECTION_MARKER).strip
      return if text.blank?

      label("## #{text}")
    end

    # True when the question already names the board a heading declares.
    #
    # Only the heading's identifier-shaped tokens are required: a real heading
    # mixes the board name with free descriptive prose ("ARCA II Safety Chain &
    # Connector Layout", "Tabla de LEDs de la cadena serie — MICONIC LX"), so
    # demanding every prose word would report every board as unnamed. Three
    # rules keep that permissiveness from over-matching: every digit-bearing
    # token must match (TPR60 vs TPR70), every ≤3-char token must match (ARCA
    # vs ARCA III), and at least one token must match at all.
    def mentioned?(heading, question)
      tokens = board_tokens(heading)
      return false if tokens.empty?

      asked = norm(question)
      return false if asked.empty?

      return tokens.all? { |token| token_match?(token, asked) } if fully_qualified?(tokens)

      return false unless tokens.any? { |token| token_match?(token, asked) }
      return false unless tokens.select { |token| token.match?(/\d/) }.all? { |token| token_match?(token, asked) }

      tokens.select { |token| token.length <= SHORT_WORD_CHARS }.all? { |token| token_match?(token, asked) }
    end

    # A board name with no digit to anchor on has nothing else load-bearing
    # enough to skip once it is down to a token or two: "ARCA" alone must not
    # absorb a question that names the sibling "ARCA BASICO" or "ARCA III"
    # instead, so every token is required. A longer heading (>2 tokens) still
    # relies on the digit/short rule below — that is what lets a manufacturer
    # prefix/suffix ("HIDRA", "INAPELSA") ride along unmatched.
    def fully_qualified?(tokens)
      tokens.size <= 2 && tokens.none? { |token| token.match?(/\d/) }
    end
    private_class_method :fully_qualified?

    # Public: Rag::StructuredEvidenceRoute's comparative-selection pass reuses
    # this to compare two named boards' tokens for its specificity rule.
    #
    # Empty means the heading is generic prose with no board name in it at all
    # (a bare table/diagram caption) — callers use that to skip it as a board
    # identity and fall back to metadata instead.
    def board_tokens(heading)
      norm(heading).reject { |token| STOP.include?(token) }
    end

    # Strips the "**Section:**"-style prefix line, footnote parentheticals and
    # unicode dashes, then merges a split "NAME 1234" into "NAME1234" (D1: the
    # tokenizer otherwise treats board name and model number as two words, one
    # of which — the bare number — collides across unrelated boards) before
    # splitting into identifier-shaped tokens. Pure section markers ("S7") are
    # dropped: they are page structure, never part of a board name.
    def norm(text)
      folded = fold(text)
        .sub(SECTION_PREFIX_LINE, " ")
        .gsub(PARENTHETICAL, " ")
        .gsub(/[‐-―−]/, " ")
        .gsub(/\b([A-Z]{2,})\s+(\d{1,4})\b/) { "#{$1}#{$2}" }

      folded.scan(/[[:alnum:]]+(?:-[[:alnum:]]+)*/).reject { |token| token.match?(SECTION_TOKEN) }
    end
    private_class_method :norm

    # A compound token ("TWISTER-TW") also matches through any of its parts
    # (D2), so a heading that adds a brand suffix ("TWISTER TW - INAPELSA")
    # does not force the question to repeat that suffix verbatim.
    def token_match?(token, question_words)
      [ token, *token.split("-") ].uniq.any? do |part|
        question_words.any? { |word| word_match?(part, word) && !sibling_conflict?(part, word) }
      end
    end
    private_class_method :token_match?

    # word_match?'s shared-prefix allowance exists for gender/plural spelling
    # ("BASICO" vs "básica"), but the same rule also accepts sibling board
    # designators that differ only in their trailing model digit
    # ("EDEL-K3" vs "EDEL-K2": six characters in common, past
    # MIN_COMMON_PREFIX, before the digit that is the only thing telling them
    # apart — H-03). Once a digit sits in the part either string contributes
    # past their common root, only exact equality may count as a match.
    def sibling_conflict?(part, word)
      return false if part == word

      root_length = common_prefix_length(part, word)
      part[root_length..].match?(/\d/) || word[root_length..].match?(/\d/)
    end
    private_class_method :sibling_conflict?

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
