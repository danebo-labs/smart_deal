# frozen_string_literal: true

module Rag
  # Removes an order to decrease a parameter below the minimum that a retrieved
  # passage states for that same parameter. It only deletes: it never adds or
  # rewrites text, and it does not decide whether a quote is literal.
  #
  # A minimum belongs to a parameter only when one statement of the passage
  # holds the decrease instruction, the «mínimo de N» and exactly one parameter
  # token. A neighbouring line, a figure that merely looks alike, or the
  # minimum of another parameter attribute nothing.
  #
  # An order is judged per clause, so «No reinicies y baja KP-VS» is two
  # actions and the negation covers only the first. Only the offending clause
  # leaves; the cited evidence in the same sentence stays.
  class CompanionCitedFloor
    HYPHENS = /[\u2010\u2011\u2012\u2013\u2212]/
    PARAMETER = /(?<![[:alnum:]-])[A-Z]{2,}(?:-[A-Z0-9]+)+(?![[:alnum:]-])/
    NUMBER = /\d+(?:[.,]\d+)?/

    MINIMUM = /(?:m[ií]nimo|minimum)(?:\s+(?:de|of)|:)?\s*\[?(#{NUMBER})\]?/i
    SOURCE_DECREASE = /disminu|diminu|reduc|reduz|baj|decrease|lower|decrement/i
    REPORTED = /(#{PARAMETER})(?:(?!#{PARAMETER})[^\d.;!?\n]){0,25}?(#{NUMBER})/

    CLITIC = "(?:l[oae]s?)?"
    DECREASE = /
      (?<![[:alnum:]])(?:
        red[uú]ce#{CLITIC} | reducir#{CLITIC} | reduzca(?:s|n|mos)?#{CLITIC} |
        dismin(?:uy(?:e|a|as|an)|úy(?:e|a)|uir)#{CLITIC} |
        b[aá]ja#{CLITIC} | baje(?:s|n|mos)?#{CLITIC} | bajar#{CLITIC} |
        reb[aá]ja#{CLITIC} | rebaje(?:s|n)?#{CLITIC} | rebajar#{CLITIC} |
        decrement(?:a|e|ar)#{CLITIC} |
        (?:sigue|seguir|siga|contin[uú]a|continuar)\s+(?:bajando|reduciendo|disminuyendo) |
        decrease | lower | reduce
      )(?![[:alnum:]])
    /ix
    NEGATOR = /
      (?<![[:alnum:]])(?:no|nunca|jam[aá]s|tampoco|ni|sin|evit\w+|not|never|don't|do\s+not)(?![[:alnum:]])
      (?:\s+[[:alpha:]'-]+){0,3}\s*\z
    /ix
    PROCLITIC = /(?<![[:alnum:]])(?:lo|la|los|las)\s+(?:[[:alpha:]]+\s+)?\z/i
    GENERIC_OBJECT = /\A\s*(?:el|este|ese|dicho)\s+(?:valor|par[aá]metro)(?!\s+de\s+(?:la|el|los|las)\b)/i

    BELOW = /(?:por\s+debajo\s+de|menos\s+de|below)\s+\[?(#{NUMBER})\]?/i
    ARTICLE = "(?:el|un|su)"
    TARGET = /(?<![[:alnum:]])(?:a|hasta|to)\s+(?:#{ARTICLE}\s+)?(?:(?:m[ií]nimo|valor)\s+de\s+)?\[?(#{NUMBER})\]?/i
    BY = /(?<![[:alnum:]])(?:en|by)\s+\[?(#{NUMBER})\]?/i
    BOUNDED = /hasta\s+(?:#{ARTICLE}\s+)?m[ií]nimo|(?:sin|no)\s+(?:bajar|pasar|ir)\s+de/i

    SEPARATOR = /
      (?<!\d),|,(?!\d) | [;:] | \s[—–]\s | — |
      (?<![[:alnum:]])(?:
        y|e|o|u|pero|aunque|sino|pues|porque|ya\s+que|dado\s+que|as[ií]\s+que|
        por\s+lo\s+tanto|por\s+eso|entonces|and|but|or
      )(?![[:alnum:]])
    /ix
    SEPARATOR_RUN = /\s*(?:#{SEPARATOR})(?:\s*(?:#{SEPARATOR}))*\s*/ix
    LIST_MARKER = /\A\s*(?:[-*•]|\d+[.)])\s+/
    BARE_MARKER = /\A[ \t]*(?:[-*•]|\d+[.)])[ \t]*\n?\z/

    # Not whitespace: a blanked quotation must not be eaten as a separator gap.
    BLANK = "\u0001"

    Result = Struct.new(:text, :removed, keyword_init: true)
    Clause = Struct.new(:lead, :range)

    def self.call(...)
      new(...).call
    end

    def initialize(text:, sources:, technician_texts: [])
      @text = text.to_s
      @sources = Array(sources)
      @technician_texts = Array(technician_texts)
    end

    def call
      return unchanged if floors.empty?

      @masked = mask(@text)
      sentences = sentence_ranges
      edits = []
      removed = []
      sentences.each_with_index do |range, index|
        next if @masked[range].rstrip.end_with?("?")

        clauses = clauses_of(range)
        verdicts = clauses.map { |clause| verdict(clause, range, sentences, index) }
        next if verdicts.none?

        removed.concat(verdicts.zip(clauses).filter_map { |row, clause| row&.merge("sentence" => @text[range].strip, "clause" => @text[clause.range]) })
        edits << edit_for(range, clauses, verdicts)
      end
      return unchanged if edits.empty?

      body = @text.dup
      edits.sort_by(&:first).reverse_each { |from, to, replacement| body[from...to] = replacement }
      Result.new(text: tidy(body), removed: removed)
    end

    private

    def unchanged
      Result.new(text: @text, removed: [])
    end

    # {"KP-VS" => 3.0}. Only a statement with a decrease instruction, a
    # minimum and exactly one parameter counts.
    def floors
      @floors ||= @sources.each_with_object({}) do |source, found|
        content = CompanionTurnPublication.content_of(source).gsub(/\[(?:SEARCH_ALIASES|DOCUMENT|SOURCE_URI):.*?\]/m, " ")
        content.gsub(HYPHENS, "-").split(/\n+|(?<=[.!?])\s+/).each do |statement|
          minimum = statement[MINIMUM, 1]
          next if minimum.nil? || !statement.match?(SOURCE_DECREASE)

          names = statement.scan(PARAMETER).uniq
          next unless names.one?

          found[names.first] = [ found[names.first], decimal(minimum) ].compact.max
        end
      end
    end

    # companion_technician_texts puts the current message first and the
    # earlier ones oldest to newest, so the current report wins and, after it,
    # the latest one. A question is a proposal, not a report.
    def reported
      @reported ||= begin
        values = {}
        @technician_texts.drop(1).each { |text| values.merge!(reports_in(text)) }
        values.merge!(reports_in(@technician_texts.first))
      end
    end

    def reports_in(text)
      text.to_s.gsub(HYPHENS, "-").split(/(?<=[.!?])\s+|\n/).each_with_object({}) do |sentence, values|
        next if sentence.match?(/[?¿]/)

        sentence.scan(REPORTED) { |name, number| values[name] = decimal(number) }
      end
    end

    # Same length as @text, so a position in one is a position in the other.
    # A long quotation is blanked (BLANK); a short quoted label such as "KP-VS" is not.
    def mask(text)
      text.gsub(HYPHENS, "-").gsub(CompanionTurnPublication::QUOTE_PATTERN) do |quote|
        quote.split.size >= 4 ? BLANK * quote.length : quote
      end
    end

    def sentence_ranges
      ranges = []
      start = 0
      index = 0
      while index < @masked.length
        char = @masked[index]
        if char == "\n"
          ranges << (start...index)
          start = index + 1
        elsif char.match?(/[.!?]/) && boundary?(index)
          index += 1 while @masked[index + 1]&.match?(/[.!?]/)
          ranges << (start...(index + 1))
          start = index + 1
        end
        index += 1
      end
      ranges << (start...@masked.length) if start < @masked.length
      ranges.filter_map do |range|
        head = @masked[range]
        next if head.strip.empty?

        offset = head[/\A\s*/].length + (head.sub(/\A\s+/, "")[LIST_MARKER]&.length || 0)
        (range.begin + offset)...range.end
      end
    end

    def boundary?(index)
      following = @masked[index + 1]
      return false unless following.nil? || following.match?(/[[:space:]]/)
      return true unless @masked[index] == "."

      word = @masked[0...index][/([[:alpha:]º]+)\z/, 1].to_s.downcase
      !(word.length > 1 && CompanionClaimBacking::ABBREVIATIONS.include?(word))
    end

    # The sentence without its closing punctuation, split on commas that are
    # not decimals, colons, dashes and conjunctions. Each clause keeps the
    # separator that preceded it.
    def clauses_of(range)
      closing = @masked[range][/[.!?\s]*\z/].length
      limit = range.end - closing
      limit = range.end if limit <= range.begin
      span = @masked[range.begin...limit]
      clauses = []
      cursor = 0
      lead = ""
      span.to_enum(:scan, SEPARATOR_RUN).each do
        match = Regexp.last_match
        clauses << body_clause(range.begin, cursor, match.begin(0), lead)
        lead = @text[(range.begin + match.begin(0))...(range.begin + match.end(0))]
        cursor = match.end(0)
      end
      clauses << body_clause(range.begin, cursor, span.length, lead)
      clauses.compact
    end

    # The body is read from the original text: a quotation blanked in the
    # masked copy is still content of its clause.
    def body_clause(base, from, to, lead)
      body = @text[(base + from)...(base + to)]
      return nil if body.strip.empty?

      first = base + from + body[/\A\s*/].length
      last = base + from + body.rstrip.length
      Clause.new(lead, first...last)
    end

    # nil, or the row that records why this clause is removed.
    # The verb is searched outside the quotations, so a quoted «redúcelo» is
    # not an order. The bound or target it is given is read with the quotation
    # in place: «disminuir el valor «hasta el mínimo de [3,0]»» is bounded.
    def verdict(clause, sentence, sentences, index)
      text = @masked[clause.range]
      written = @text[clause.range].gsub(HYPHENS, "-")
      text.to_enum(:scan, DECREASE).each do
        match = Regexp.last_match
        next if text[0...match.begin(0)].match?(NEGATOR)

        name = parameter_of(text, match, sentence, sentences, index)
        floor = floors[name]
        next if floor.nil?

        rest = written[match.end(0)..]
        target = proposed(rest, reported[name])
        next unless below?(target, floor, reported[name], rest)

        return {
          "reason" => "below_cited_minimum", "parameter" => name, "minimum" => floor,
          "reported" => reported[name], "target" => target
        }
      end
      nil
    end

    def parameter_of(text, match, sentence, sentences, index)
      named = text.scan(PARAMETER).uniq
      return named.first if named.one?
      return nil if named.any?
      return nil unless implied_object?(text, match)

      own = @masked[sentence].scan(PARAMETER).uniq
      return own.first if own.one?
      return nil if own.any?

      before = sentences[index - 1] if index.positive?
      return nil unless before && @masked[before.end...sentence.begin].exclude?("\n")

      previous = @masked[before].scan(PARAMETER).uniq
      previous.one? ? previous.first : nil
    end

    # «redúcelo», «lo reduzcas», «reduce el valor»: the object is whatever the
    # sentence was just about.
    def implied_object?(text, match)
      match[0].match?(/l[oae]s?\z/i) ||
        text[0...match.begin(0)].match?(PROCLITIC) ||
        text[match.end(0)..].match?(GENERIC_OBJECT)
    end

    # A number this order moves the value to, when the clause says so.
    def proposed(rest, reported_value)
      if (below = rest[BELOW, 1])
        return decimal(below) - 0.0001
      end
      if (target = rest[TARGET, 1])
        return decimal(target)
      end
      return nil unless reported_value && (delta = rest[BY, 1])

      reported_value - decimal(delta)
    end

    def below?(target, floor, reported_value, rest)
      return target < floor unless target.nil?
      return false if rest.match?(BOUNDED)

      !reported_value.nil? && reported_value <= floor
    end

    # Removes the offending clauses and puts the others back together with
    # the separators they had. Nothing left means the sentence goes.
    def edit_for(range, clauses, verdicts)
      kept = +""
      pending = nil
      shifted = false
      clauses.zip(verdicts).each do |clause, row|
        if row
          pending ||= clause.lead
          shifted = true
          next
        end

        body = @text[clause.range]
        if kept.empty?
          body = body.sub(/\A\p{Ll}/) { |letter| letter.upcase } if shifted || !clause.lead.empty?
          kept << body
        else
          kept << (pending || clause.lead) << body
        end
        pending = nil
      end

      if kept.empty?
        tail = @text[range.end..].to_s[/\A[ \t]*/].length
        [ range.begin, range.end + tail, "" ]
      else
        [ clauses.first.range.begin, clauses.last.range.end, kept ]
      end
    end

    def tidy(body)
      lines = body.gsub(/[ \t]+\n/, "\n").lines.reject { |line| line.match?(BARE_MARKER) }
      lines.join.gsub(/\n{3,}/, "\n\n").strip
    end

    def decimal(token)
      token.to_s.tr(",", ".").to_f
    end
  end
end
