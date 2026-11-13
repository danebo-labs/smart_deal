# frozen_string_literal: true

module Rag
  # Sentence-level filter for a companion-direct answer, before
  # CompanionTurnPublication. A sentence that cites [n] must carry a literal
  # quote of that source; otherwise only the sentence is dropped and the rest
  # of the orientation survives. It never adds text. The only rewrite is the
  # [n] of a sentence whose quotes are literal in exactly one other source of
  # the turn, and that sentence passes every check again under the new [n].
  class CompanionClaimBacking
    # A label such as «PasCom 24V» or «+» names a thing; it does not back
    # what the sentence says about it.
    MIN_BACKING_WORDS = 4
    CITATION_PATTERN = CompanionTurnPublication::CITATION_PATTERN
    QUOTE_PATTERN = CompanionTurnPublication::QUOTE_PATTERN
    # Bold is also used for labels, so it only counts when it is literal.
    BOLD_PATTERN = /\*\*([^*]+)\*\*/.freeze
    LIST_PREFIX = /\A(\s*(?:[-*•]|\d+[.)])\s+)/.freeze
    ABBREVIATIONS = %w[p pp pág págs fig sec núm nº n aprox máx mín ej etc approx max min].freeze
    OPENERS = { "«" => "»", "“" => "”", '"' => '"' }.freeze
    # «No sé cómo identificar #21», «no puedo medir», «can't check». Not
    # «no sé si…», which is doubt the technician can still check.
    INABILITY = /(?<![[:alnum:]])(?:no\s+(?:s[ée]|sabr[ií]a|puedo|podr[ií]a|consigo|logro)(?:\s+(?:c[oó]mo|bien))?|can(?:'|no)?t|(?:do\s+not|don't)\s+know\s+how\s+to)\s+(?:identificar|comprobar|verificar|medir|ver|saber|revisar|localizar|ubicar|encontrar|distinguir|identify|check|verify|measure|tell|find|locate)(?![[:alnum:]])[^.!?]*/i.freeze
    ACTION_LEAD = /\A[[:space:]*_]*(?:¿\s*)?(?:(?:puedes|podr[ií]as|necesito\s+que)\s+)?((?:confirm|comprob|comprueb|verific|revis|identific|ubic|localiz|med[ií]r|mid[ae]|chequ|inspeccion|check|verify|measure|inspect|identify|locate)[[:alpha:]]*)(?![[:alpha:]]*:)/i.freeze
    INLINE_LABEL = /\A\s*\*\*[^*]+:\*\*\s*/.freeze
    REPORTED_FORM = /(?:aste|asteis|aron|ieron|ado|ada|ados|adas|ido|ida|ed)\z/i.freeze
    MAX_CARRY_PASSES = 3
    # «ese mínimo»: points at a limit that an earlier sentence quoted.
    DANGLING_LIMIT = /(?<![[:alnum:]])(?:ese|dicho|este)\s+(?:m[ií]nimo|l[ií]mite)/i.freeze
    STATED_LIMIT = /\bno\s+(?:puedes|puede|sabes|es\s+posible)\b|\bsin\s+poder\b|\bcannot\b|\bcan't\b/i.freeze

    Result = Struct.new(:text, :removed, :reattributed, keyword_init: true) do
      def changed?
        removed.any? || reattributed.to_a.any?
      end

      def to_h
        { "removed" => removed, "reattributed" => reattributed.to_a, "changed" => changed? }
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(text:, sources:, technician_texts: [], manufacturer: nil)
      @text = text.to_s
      @sources = Array(sources)
      @technician_texts = Array(technician_texts)
      @manufacturer = manufacturer
      @removed = []
      @reattributed = []
      @context = []
    end

    def call
      lines = filter_lines
      lines = carry_quotes(lines)
      lines = drop_dangling_limits(lines)
      lines = drop_orphan_labels(lines) if changed?
      body = lines.join("\n").gsub(/\n{3,}/, "\n\n").strip
      Result.new(text: body, removed: @removed, reattributed: @reattributed)
    end

    private

    def filter_lines
      @text.split("\n", -1).filter_map { |line| filter_line(line) }
    end

    # A limit quoted on its own keeps its passage condition when a kept
    # sentence quotes that condition, and a comparison keeps the limit a kept
    # sentence quotes. Only quotes that survived the previous pass can carry,
    # so a removed sentence never vouches for another. A quote that survives
    # only thanks to the context can in turn carry the comparison that names
    # it, so the pass repeats while the kept quotes grow. Three passes at most.
    def carry_quotes(lines)
      MAX_CARRY_PASSES.times do
        break unless @removed.any? { |item| %w[unverified_quote uncited_attribution].include?(item["reason"]) }

        kept = lines.join("\n").scan(QUOTE_PATTERN).flatten.compact
        break if kept.empty? || kept.sort == @context.sort

        @removed = []
        @reattributed = []
        @context = kept
        lines = filter_lines
      end
      lines
    end

    def changed?
      @removed.any?
    end

    # «Esa lectura está por debajo de ese mínimo» has no referent once the
    # sentence that quoted the limit left. Without a kept quote of a limit
    # anywhere in the answer, the sentence that points at it leaves too.
    def drop_dangling_limits(lines)
      return lines if lines.join("\n").scan(QUOTE_PATTERN).flatten.compact.any? { |text| text.match?(BoundComparison::LIMIT_WORD) }

      lines.filter_map do |line|
        next line unless line.match?(DANGLING_LIMIT)

        prefix = line[LIST_PREFIX, 1].to_s
        kept = sentences(line.delete_prefix(prefix)).reject do |sentence|
          sentence.match?(DANGLING_LIMIT) && @removed.push("sentence" => sentence, "reason" => "dangling_limit")
        end
        "#{prefix}#{kept.join(' ')}" if kept.any?
      end
    end

    # A heading such as «**Pasos a seguir:**» loses its meaning once the
    # lines it introduced were dropped.
    def drop_orphan_labels(lines)
      lines.each_with_index.reject do |line, index|
        next false unless label?(line)

        following = lines[(index + 1)..].to_a.find { |item| !item.strip.empty? }
        following.nil? || label?(following) || following.strip.start_with?("¿")
      end.map(&:first)
    end

    def label?(line)
      line.strip.gsub("**", "").end_with?(":")
    end

    def filter_line(line)
      return line if line.strip.empty?

      prefix = line[LIST_PREFIX, 1].to_s
      kept = sentences(line.delete_prefix(prefix)).filter_map { |sentence| kept_sentence(sentence) }
      return nil if kept.empty?

      "#{prefix}#{kept.join(' ')}"
    end

    def kept_sentence(sentence)
      reason = drop_reason(sentence)
      return sentence if reason.nil?

      moved = reattributed(sentence) if reason == "unverified_quote"
      return moved if moved

      @removed << { "sentence" => sentence, "reason" => reason }
      nil
    end

    # Only a single [n], and only when one other citable source holds every
    # quote with its condition; several or none keep the rejection.
    def reattributed(sentence)
      numbers = sentence.scan(CITATION_PATTERN).flatten.map(&:to_i).uniq
      return nil unless numbers.one?

      quotes = documentary_quotes(sentence, QUOTE_PATTERN)
      return nil if quotes.empty?

      holders = @sources.each_index.select do |index|
        source = @sources[index]
        index != numbers.first - 1 && CompanionTurnPublication.citable_source?(source) &&
          quotes.all? { |quoted, lead| verified?(quoted, [ source ], lead) }
      end
      return nil unless holders.one?

      target = holders.first + 1
      moved = sentence.gsub("[#{numbers.first}]", "[#{target}]")
      return nil unless drop_reason(moved).nil?

      @reattributed << { "sentence" => sentence, "from" => numbers.first, "to" => target }
      moved
    end

    def drop_reason(sentence)
      return nil if CompanionTurnPublication.not_loaded_sentence?(sentence)
      return "returns_unverifiable" if returns_unverifiable?(sentence)
      return nil if CompanionTurnPublication.technician_sentence?(sentence)

      numbers = sentence.scan(CITATION_PATTERN).flatten.map(&:to_i).uniq
      return uncited_reason(sentence) if numbers.empty?

      pool = numbers.map { |number| number.positive? ? @sources[number - 1] : nil }
      return "missing_source" if pool.any?(&:nil?)
      return "not_citable" unless pool.all? { |source| CompanionTurnPublication.citable_source?(source) }

      checks = documentary_quotes(sentence, QUOTE_PATTERN).map { |quoted, lead| [ quoted, verified?(quoted, pool, lead) ] }
      return "unverified_quote" if checks.any? { |_quoted, ok| !ok }

      bold = documentary_quotes(sentence, BOLD_PATTERN).select { |quoted, lead| verified?(quoted, pool, lead) }
      return "unbacked_citation" unless (checks.map(&:first) + bold.map(&:first)).any? { |quoted| backing?(quoted) }
      return "unbacked_residue" if foreign_tokens?(sentence, pool)

      nil
    end

    # What the technician said they cannot identify or check is a limit of
    # the case, not a pending action handed back under another wording.
    def returns_unverifiable?(sentence)
      verb = sentence.sub(INLINE_LABEL, "")[ACTION_LEAD, 1]
      return false if verb.nil? || verb.match?(REPORTED_FORM)
      return false if sentence.match?(STATED_LIMIT)

      text = sentence.downcase.delete("#")
      unverifiable_keys.any? { |key| text.match?(/(?<![[:alnum:]])#{Regexp.escape(key)}(?![[:alnum:]])/) }
    end

    def unverifiable_keys
      @unverifiable_keys ||= @technician_texts.flat_map { |text|
        text.to_s.scan(INABILITY).flat_map { |clause| clause_keys(clause) }
      }.uniq
    end

    # «#21» stays a key; a bare «3» keeps the word before it («nivel 3»).
    def clause_keys(clause)
      clause.scan(CompanionPlanEvidence::LABEL_TOKEN).filter_map do |token|
        key = token.delete_prefix("#").downcase
        next key if key.length >= CompanionPlanEvidence::MIN_LABEL_CHARS

        clause[/([[:alpha:]]+)\s+#?#{Regexp.escape(token.delete_prefix('#'))}(?![[:alnum:]])/, 1]&.downcase&.then { |word| "#{word} #{key}" }
      end
    end

    # A literal quote does not carry an identifier or value written next to it.
    def foreign_tokens?(sentence, pool)
      residue = sentence.gsub(QUOTE_PATTERN, " ").gsub(BOLD_PATTERN, " ").gsub(CITATION_PATTERN, " ")
      bodies = pool.flat_map { |source| [ CompanionTurnPublication.content_of(source), source["document"].to_s ] } +
        @technician_texts.map(&:to_s)
      labels = residue.scan(CompanionPlanEvidence::LABEL_TOKEN).select { |token| token.length >= CompanionPlanEvidence::MIN_LABEL_CHARS }
      (CompanionTurnPublication.claim_tokens(residue) + labels).uniq.any? do |token|
        bodies.none? { |body| body.include?(token) }
      end
    end

    def uncited_reason(sentence)
      checks = documentary_quotes(sentence, QUOTE_PATTERN).map { |quoted, lead| verified?(quoted, @sources, lead) }
      return "unverified_quote" if checks.any?(false)
      return nil unless CompanionTurnPublication.source_attribution?(sentence, @manufacturer)
      return nil if CompanionTurnPublication.source_absence?(sentence)
      return nil if CompanionTurnPublication.question_sentence?(sentence)
      return nil if sentence.strip.end_with?(":")
      return nil if bound_comparison?(sentence)

      "uncited_attribution"
    end

    def bound_comparison?(sentence)
      BoundComparison.call(
        sentence: sentence, quotes: @context, technician_texts: @technician_texts,
        sources: @sources.select { |source| CompanionTurnPublication.citable_source?(source) }
      )
    end

    def documentary_quotes(sentence, pattern)
      sentence.to_enum(:scan, pattern).filter_map do
        match = Regexp.last_match
        quoted = match.captures.compact.first.to_s.strip
        next if quoted.empty?
        next if CompanionTurnPublication.technician_text?(quoted, @technician_texts)

        [ quoted, sentence[0...match.begin(0)].to_s ]
      end
    end

    def verified?(quoted, pool, lead)
      match = CompanionTurnPublication.verified_quote(quoted, pool, lead, @context)
      !match.nil? && !match[:condition_dropped]
    end

    def backing?(quoted)
      quoted.split.count { |word| word.match?(/[[:alnum:]]/) } >= MIN_BACKING_WORDS
    end

    # A period inside a quotation, a decimal, or a short abbreviation does not
    # end the sentence. A [n] run right after the end stays with it.
    def sentences(line)
      parts = []
      current = +""
      closer = nil
      index = 0
      while index < line.length
        char = line[index]
        current << char
        index += 1
        if closer
          next unless char == closer

          closer = nil
          next unless current[-2].to_s.match?(/[.!?]/) && boundary?(line, index)
        elsif OPENERS.key?(char)
          closer = OPENERS[char]
          next
        elsif !(char.match?(/[.!?]/) && boundary?(line, index) && !abbreviation?(current))
          next
        end
        run = line[index..].to_s[/\A(?:[[:space:]]*\[\d+\])+/].to_s
        current << run
        index += run.length
        parts << current.strip
        current = +""
      end
      parts << current.strip
      parts.reject(&:empty?)
    end

    def boundary?(line, index)
      nxt = line[index]
      nxt.nil? || nxt.match?(/[[:space:]\[]/)
    end

    def abbreviation?(current)
      return false unless current.end_with?(".")

      word = current[0...-1].to_s[/([[:alpha:]º]+)\z/, 1].to_s.downcase
      ABBREVIATIONS.include?(word)
    end
  end
end
