# frozen_string_literal: true

module Rag
  # Sentence-level filter for a companion-direct answer, before
  # CompanionTurnPublication. A sentence that cites [n] must carry a literal
  # quote of that source; otherwise only the sentence is dropped and the rest
  # of the orientation survives. It never rewrites or adds text.
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
    STATED_LIMIT = /\bno\s+(?:puedes|puede|sabes|es\s+posible)\b|\bsin\s+poder\b|\bcannot\b|\bcan't\b/i.freeze

    Result = Struct.new(:text, :removed, keyword_init: true) do
      def changed?
        removed.any?
      end

      def to_h
        { "removed" => removed, "changed" => changed? }
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
    end

    def call
      lines = @text.split("\n", -1).filter_map { |line| filter_line(line) }
      lines = drop_orphan_labels(lines) if changed?
      body = lines.join("\n").gsub(/\n{3,}/, "\n\n").strip
      Result.new(text: body, removed: @removed)
    end

    private

    def changed?
      @removed.any?
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
      kept = sentences(line.delete_prefix(prefix)).select { |sentence| keep?(sentence) }
      return nil if kept.empty?

      "#{prefix}#{kept.join(' ')}"
    end

    def keep?(sentence)
      reason = drop_reason(sentence)
      return true if reason.nil?

      @removed << { "sentence" => sentence, "reason" => reason }
      false
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
      bodies = pool.map { |source| CompanionTurnPublication.content_of(source) } + @technician_texts.map(&:to_s)
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

      "uncited_attribution"
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
      match = CompanionTurnPublication.verified_quote(quoted, pool, lead)
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
