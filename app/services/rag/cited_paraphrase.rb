# frozen_string_literal: true

module Rag
  # A cited sentence may translate or paraphrase its source. Words inside
  # quotation marks still have to be the source's own text; CompanionClaimBacking
  # checks that before it asks here. What remains is kept when it names the
  # same entities with the same scope and the same conditions. A conditional
  # branch stated as the confirmed cause is not that translation.
  class CitedParaphrase
    STOPWORDS = %w[
      el la los las un una de del al y e o u en con por para que su sus
      este esta estos estas ese esa esos esas lo le se es son como mas muy
      dos tres da do das dos em na no ao os as um uma the of and
    ].freeze
    # Words that frame a sentence (where the passage is, that it happens, that
    # one thing follows another) and say nothing a source line has to contain.
    RHETORIC = %w[
      segun indica indican abarca incluye incluyen comprende comprenden cubre
      corresponden corresponde destaca destacan senala caso casos fuente manual
      siguiente tambien donde dentro entre cuando quando
      tabla tablas ocurre ocurren sucede suceden aparece aparecen produce producen
      porque pues
      referencia referencias condicional condicionales figura figuran codigo codigos
      logra lograr logran capaz significa significan
    ].freeze
    PAIRS = [
      %w[fiacao cableado], %w[sinais senales], %w[sinal senal], %w[porta puerta],
      %w[alguna cualquiera], %w[alguno cualquiera], %w[permitido programado]
    ].freeze
    # One idea in several verbs: the signal is no longer there. A source that
    # says «desaparecer» backs «faltar» and «perdió», nothing else.
    LOSS_ROOTS = %w[desaparec perd pierd falt ausen].freeze
    # One idea in several verbs: look at, check. A source that says «Comprobar
    # señales» backs «revisar las señales». The entity and the object still
    # have to be in the line.
    CHECK_ROOTS = %w[revis comprob comprueb verific chequ].freeze
    # Endings that make two forms of one verb (cerró, cerrar, cerrado) meet.
    VERB_ENDINGS = %w[aron ieron aban ando iendo ado ido ar er ir an en o a e].freeze
    # A source line that lists alternatives («DCL, DFC o DW»). A sentence that
    # names only some of them as the lost one or the cause has chosen a branch.
    ALTERNATIVES = /(?<![[:alnum:]])([[:upper:]][[:alnum:]-]+(?:\s*,\s*[[:upper:]][[:alnum:]-]+)*)\s*(?:,\s*)?(?:o|ó|u|ou|or)\s+([[:upper:]][[:alnum:]-]+)(?![[:alnum:]])/
    # «Alguna de» restates the «ó» of a line that lists alternatives; the
    # alternatives themselves are still checked one by one.
    ANY_OF = %w[alguna alguno algunas algunos cualquiera].freeze
    CHOICE_CUE = /\b(?:porque|causa|debido|se\s+debe|origina|provoca)\b|(?:desaparec|perd|pierd|falt|ausen)[[:alpha:]]*/i
    FAILURE_WORDS = /\A(?:falha|falla|fallo|falhas|fallas)\z/i
    CONDITION = /(?<![[:alnum:]])(?:quando|cuando|si|if|when|unless|salvo|excepto|solo|sólo)(?![[:alnum:]])|\ben caso\b|\ba menos\b/i
    CONFIRMATION = /\b(?:causa confirmada|la causa|es la causa|cualquier|qualquer|siempre|sempre|se debe a|confirma que)\b/i
    ACTION = /(?<![[:alpha:]])(?:revis|comprob|comprueb|verific|desconect|testar|trocar)[[:alpha:]]*/i

    QUANTITY = /(?<![[:alnum:].,+−-])([+−-]?\d+(?:[.,]\d+)?)\s*(V(?:AC|CA|DC|CC)?|mV|[mµ]A|(?-i:A)|Hz|Nm|bar|mm|cm|°C|rpm|kW|%)(?![[:alnum:]])/i
    UNIT_EQUIVALENTS = { "vcc" => "vdc", "vca" => "vac" }.freeze

    def self.normalize_units(text)
      text.gsub(QUANTITY) do
        match = Regexp.last_match
        unit = match[2].downcase
        match[0].sub(/#{Regexp.escape(match[2])}\z/, UNIT_EQUIVALENTS.fetch(unit, unit).upcase)
      end
    end

    def self.faithful?(sentence, sources)
      new(sentence, sources).faithful?
    end

    def initialize(sentence, sources)
      @sentence = sentence.to_s
      @sources = Array(sources)
    end

    def faithful?
      return false if clauses.empty?
      return false if confirms_branch?
      return false if chooses_alternative?
      return false if added_condition?
      values = self.class.quantities(residue)
      return false if values.any? && clauses.none? do |clause|
        (values - self.class.quantities(clause)).empty? && anchors.all? { |anchor| anchor_in?(clause, anchor) }
      end
      return false if anchors.empty? && required.empty? && literal_quotes.none? { |quote| quote.split.size >= 2 }
      return false if uncovered?

      covered_tokens.all? { |token| condition_kept?(token) }
    end

    private

    def self.quantities(text)
      text.scan(QUANTITY).map do |value, unit|
        [ BigDecimal(value.tr(",−", ".-")), UNIT_EQUIVALENTS.fetch(unit.downcase, unit.downcase) ]
      end
    end

    def confirms_branch?
      residue.match?(CONFIRMATION) && clauses.any? do |clause|
        conditional?(clause) && anchors.any? { |anchor| anchor_in?(clause, anchor) }
      end
    end

    # «Se perdió DCL» when the line says «perdido DCL, DFC ó DW»: one of the
    # alternatives presented as the one that is missing.
    def chooses_alternative?
      return false unless residue.match?(CHOICE_CUE)

      named = anchors.map { |anchor| norm(anchor) }
      clauses.any? do |clause|
        clause.scan(ALTERNATIVES).any? do |head, last|
          group = (head.split(/\s*,\s*/) + [ last ]).map { |item| norm(item) }
          (group & named).any? && (group - named).any?
        end
      end
    end

    def added_condition?
      return false unless conditional?(residue)

      condition_words(residue).any? { |word| clauses.none? { |clause| word_in?(clause, word) } }
    end

    def uncovered?
      (anchors + required).any? { |token| clauses.none? { |clause| token_in?(clause, token) } }
    end

    def condition_kept?(token)
      covers = clauses.select { |clause| token_in?(clause, token) }
      return false if covers.empty?
      return true if covers.any? { |clause| !conditional?(clause) }

      covers.any? { |clause| condition_carried?(clause) }
    end

    def condition_carried?(clause)
      extra = condition_words(clause)
      if extra.any?
        extra.all? { |word| word_in?(residue, word) }
      elsif residue.match?(ACTION)
        conditional?(residue)
      else
        true
      end
    end

    def covered_tokens
      anchors + required
    end

    def anchors
      @anchors ||= residue.scan(/[[:alnum:]]+(?:-[[:alnum:]]+)*/).select { |token| token.match?(/\d/) || token.match?(/\A[[:upper:]]{2,}\z/) }
    end

    def required
      @required ||= residue.scan(/[[:alnum:]]+/).select { |token| required?(token) }
    end

    def required?(token)
      word = bare(token)
      word.length >= 4 && STOPWORDS.exclude?(word) && RHETORIC.exclude?(word) && !token.match?(/\d/) && !token.match?(FAILURE_WORDS)
    end

    def residue
      @residue ||= @sentence.gsub(CompanionTurnPublication::QUOTE_PATTERN, " ")
        .gsub(CompanionTurnPublication::CITATION_PATTERN, " ")
        .gsub(/\*\*[^*]+\*\*/, " ")
    end

    def clauses
      @clauses ||= begin
        chosen = lines
        quoted = literal_quotes.select { |quote| lines.any? { |line| includes_quote?(line, quote) } }
        chosen = lines.select { |line| quoted.all? { |quote| includes_quote?(line, quote) } } if quoted.any?
        chosen.flat_map { |line| line.split(/\s*;\s*/) }
      end
    end

    def lines
      @lines ||= @sources.flat_map { |source|
        CompanionTurnPublication.content_of(source)
          .gsub(/\[(?:SEARCH_ALIASES|DOCUMENT|SOURCE_URI):.*?\]/m, " ")
          .split(/\n+/)
          .map(&:strip)
          .reject(&:empty?)
      }
    end

    def literal_quotes
      @literal_quotes ||= @sentence.to_enum(:scan, CompanionTurnPublication::QUOTE_PATTERN).filter_map do
        Regexp.last_match.captures.compact.first.to_s.strip.presence
      end
    end

    def conditional?(text)
      text.to_s.match?(CONDITION)
    end

    def condition_words(text)
      body = text.to_s
      match = body.match(CONDITION)
      return [] unless match

      after = body[match.end(0)..].to_s
      cut = after.index(ACTION)
      span = cut ? after[0...cut] : after
      span.scan(/[[:alnum:]]+/).select { |token| required?(token) && !anchor_token?(token) }
    end

    def anchor_token?(token)
      token.match?(/\d/) || token.match?(/\A[[:upper:]]{2,}\z/)
    end

    def token_in?(clause, token)
      return true if ANY_OF.include?(norm(token)) && clause.match?(ALTERNATIVES)
      # «no aparecieron» restates «desaparecer» or «perdido». Without the
      # negation, «aparecieron» is the opposite and stays uncovered.
      return true if negated_appearance?(token) && loss_in?(clause)
      # «señales DCL, DFC o DW» names the items a row lists. «la señal es ^DCL»
      # does not: one quoted code is not that list, so «señal» stays required.
      return true if signal_category?(token) && lists_named_signals?(clause)

      anchor_token?(token) ? anchor_in?(clause, token) : word_in?(clause, token)
    end

    def signal_category?(token)
      %w[senal senale senales].include?(bare(token))
    end

    def lists_named_signals?(clause)
      named = anchors.select { |anchor| anchor.match?(/\A[[:upper:]]{2,}\z/) }
      named.size >= 2 && clause.match?(ALTERNATIVES) && named.all? { |name| anchor_in?(clause, name) }
    end

    def negated_appearance?(token)
      norm(token).start_with?("aparec") && residue.match?(/\bno\s+aparec/i)
    end

    def loss_in?(clause)
      clause.to_s.scan(/[[:alnum:]]+/).any? { |word| LOSS_ROOTS.any? { |root| norm(word).start_with?(root) } }
    end

    def anchor_in?(text, anchor)
      text.to_s.scan(/[[:alnum:]]+(?:-[[:alnum:]]+)*/).any? { |token| norm(token) == norm(anchor) }
    end

    def word_in?(text, word)
      text.to_s.scan(/[[:alnum:]]+/).any? { |token| aligns?(word, token) }
    end

    def includes_quote?(line, quote)
      squash(line).include?(squash(quote))
    end

    def aligns?(left, right)
      forms(left).product(forms(right)).any? do |one, other|
        one == other || stem(one) == stem(other) || pair?(one, other) || cognate?(stem(one), stem(other)) ||
          loss?(one, other) || check?(one, other) || same_verb?(one, other)
      end
    end

    def loss?(left, right)
      [ left, right ].all? { |word| LOSS_ROOTS.any? { |root| norm(word).start_with?(root) } }
    end

    def check?(left, right)
      [ left, right ].all? { |word| CHECK_ROOTS.any? { |root| norm(word).start_with?(root) } }
    end

    def same_verb?(left, right)
      one = verb_root(left)
      other = verb_root(right)
      one.length >= 4 && one == other
    end

    def verb_root(word)
      base = norm(word)
      ending = VERB_ENDINGS.find { |suffix| base.end_with?(suffix) && base.length - suffix.length >= 4 }
      root = ending ? base.delete_suffix(ending) : base
      # Stem change of cerrar/cierra, poder/puede: the vowel pair meets the infinitive's.
      root.sub(/ie(?=[^aeiou]+\z)/, "e").sub(/ue(?=[^aeiou]+\z)/, "o")
    end

    def pair?(left, right)
      PAIRS.any? { |one, other| (left == one && right == other) || (left == other && right == one) }
    end

    def cognate?(left, right)
      return false if left.length < 5 || right.length < 5
      return false if (left.length - right.length).abs > 1
      return false unless left[0] == right[0]

      distance(left, right) <= 1
    end

    def forms(word)
      base = norm(word)
      stripped = base.length > 4 && !base.end_with?("ss") ? base.delete_suffix("s") : base
      [ base, stripped ].uniq
    end

    def bare(word)
      forms(word).last
    end

    def stem(word)
      word.gsub(/cao\z/, "cion").gsub(/oes\z/, "ones").gsub(/ao\z/, "on")
    end

    def norm(text)
      text.to_s.downcase.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").tr("ç", "c")
    end

    def squash(text)
      norm(text).gsub(/[[:space:]]+/, " ").strip
    end

    def distance(left, right)
      previous = (0..right.length).to_a
      left.each_char.with_index do |char, i|
        current = [ i + 1 ]
        right.each_char.with_index do |other, j|
          cost = char == other ? 0 : 1
          current << [ current[j] + 1, previous[j + 1] + 1, previous[j] + cost ].min
        end
        previous = current
      end
      previous.last
    end
  end
end
