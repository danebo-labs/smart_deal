# frozen_string_literal: true

module Rag
  # Mechanical check for one companion-turn answer. It does not render,
  # regenerate, or decide that a paraphrase is faithful.
  class CompanionTurnPublication
    # Closed list. A condition on an earlier line is outside the fragment
    # and this check does not see it.
    CONDITION_WORDS = %w[
      no ni nunca si cuando salvo excepto solo sólo
      nor never if when unless except only
    ].freeze
    CONDITION_PHRASES = [ "en caso", "a menos", "in case" ].freeze
    # A source marker before a partial quote is carried when the answer puts a
    # marker of the same family before that quote.
    MARKER_FAMILIES = {
      "condition" => %w[si cuando salvo excepto if when unless except] + [ "en caso", "a menos", "in case" ],
      "negation" => %w[no ni nunca nor never],
      "restriction" => %w[solo sólo only]
    }.freeze
    CLAIM_VERBS = /\b(?:según|indica|dice|establece|pide|exige|recomienda|says|states|requires)\b/i.freeze
    QUOTE_PATTERN = /«([^»]*)»|“([^”]*)”|"([^"]*)"/.freeze
    CITATION_PATTERN = /\[(\d+)\]/.freeze
    LIST_MARKER = /(?:\A|[[:space:]])(?:[-*•]|\d+[.)])(?=[[:space:]])/.freeze
    IDENTIFIER_TOKEN = /#\d+/.freeze
    ATTRIBUTION_PATTERN = /\bmanual\b|\bdocument|\bfabricante\b|\bpasajes?\b/i.freeze
    ABSENCE_PATTERN = /(?<![[:alnum:]])\b(?:no|ni)\b(?![[:alnum:]])/i.freeze
    LIST_PATTERN = /^\s*(?:[-*•]|\d+[.)])\s+/m.freeze
    BOLD_PATTERN = /\*\*[^*]+\*\*/.freeze

    Result = Struct.new(:accepted, :reasons, :signals, :quotes, keyword_init: true) do
      def accepted?
        accepted == true
      end

      def to_h
        {
          "accepted" => accepted?,
          "reasons" => reasons,
          "signals" => signals,
          "quotes" => quotes
        }
      end
    end

    class << self
      def call(text:, sources:, stop_reason: nil, technician_texts: [], manufacturer: nil,
               guarded_text: nil, guards: [], locale: :es)
        body = text.to_s
        published = guarded_text.nil? ? body : guarded_text.to_s
        reasons = []
        signals = []
        quotes = []
        delivered = Array(sources)

        reasons.concat(source_reasons(body, delivered))
        quotes.concat(quote_findings(body, delivered, technician_texts, reasons))
        reasons.concat(attribution_reasons(body, manufacturer))
        reasons << reason("R4", "max_tokens") if stop_reason.to_s == "max_tokens"
        reasons.concat(guard_reasons(published, quotes, locale))
        signals.concat(guard_signals(guards))
        signals.concat(content_signals(body, delivered))

        Result.new(accepted: reasons.empty?, reasons: reasons, signals: signals, quotes: quotes)
      end

      def abstain_message(locale)
        I18n.t("rag.companion_contract_invalid", locale: locale)
      end

      # R5 again, after a later guard or the sanitizer. Quotes already
      # accepted must remain literally. This does not re-open R1–R4.
      def after_guards(text, publication, locale: :es)
        quotes = Array(publication.is_a?(Hash) ? publication["quotes"] : publication&.quotes)
        reasons = guard_reasons(text.to_s, quotes, locale)
        reasons.empty? ? nil : reasons
      end

      private

      def source_reasons(text, sources)
        text.to_enum(:scan, CITATION_PATTERN).map do
          number = Regexp.last_match(1).to_i
          source = sources[number - 1]
          if source.nil? || number < 1
            reason("R1", "missing:#{number}")
          elsif !citable?(source)
            reason("R1", "not_citable:#{number}")
          end
        end.compact
      end

      def citable?(source)
        data = source_hash(source)
        return false if data["reference_only"] == true || data[:reference_only] == true

        applicability = (data["applicability"] || data[:applicability]).to_s
        return false if applicability == "reference_only"

        applicability.empty? || %w[compatible neutral].include?(applicability)
      end

      def quote_findings(text, sources, technician_texts, reasons)
        found = []
        AnswerSafetyProcessor.fragments(text).each do |fragment|
          numbers = fragment.scan(CITATION_PATTERN).flatten.map(&:to_i).uniq
          next if numbers.empty?

          cited = numbers.filter_map { |number| sources[number - 1] }
          fragment.to_enum(:scan, QUOTE_PATTERN).map { Regexp.last_match }.each do |quote_match|
            quoted = quote_match.captures.compact.first.to_s
            next if quoted.strip.empty?
            next if technician_quote?(quoted, technician_texts)

            lead = fragment[0...quote_match.begin(0)].to_s
            match = documentary_quote(quoted, cited, lead)
            if match.nil?
              reasons << reason("R2", quoted)
            elsif match[:condition_dropped]
              reasons << reason("R2", "condition_dropped:#{quoted}")
            else
              found << {
                "text" => quoted,
                "source" => match[:source],
                "position" => match[:position]
              }
            end
          end
        end
        found
      end

      # nil when no cited source holds the quote literally. condition_dropped
      # when it does but a marker of the source fragment is not carried.
      def documentary_quote(quoted, sources, lead = "")
        dropped = false
        sources.each_with_index do |source, offset|
          content = source_content(source)
          next unless aligned?(content, quoted)

          fragment = AnswerSafetyProcessor.fragments(content).find { |item| fragment_match(item, quoted) }
          next unless fragment

          found = fragment_match(fragment, quoted)
          unless local_condition?(fragment, found, lead)
            dropped = true
            next
          end

          return { source: source_number(source, offset), position: found.begin(0) }
        end
        dropped ? { condition_dropped: true } : nil
      end

      def local_condition?(fragment, match, lead = "")
        before = fragment[0...match.begin(0)].to_s
        after = fragment[match.end(0)..].to_s
        return false if starts_with_marker?(after)
        return true unless marker_in?(before)

        carried?(families_in(before), lead)
      end

      def families_in(text)
        MARKER_FAMILIES.select { |_family, markers| markers.any? { |marker| marker_word?(text, marker) } }.keys
      end

      def carried?(families, lead)
        families.all? { |family| MARKER_FAMILIES[family].any? { |marker| marker_word?(lead, marker) } }
      end

      def marker_word?(text, marker)
        text.to_s.match?(/(?<![[:alnum:]])#{Regexp.escape(marker)}(?![[:alnum:]])/i)
      end

      def attribution_reasons(text, manufacturer)
        name = manufacturer.to_s.strip
        AnswerSafetyProcessor.fragments(text).filter_map do |fragment|
          next if fragment.match?(CITATION_PATTERN)
          next if fragment.match?(ABSENCE_PATTERN)
          next if question_only?(fragment)
          next unless attributes_source?(fragment, name)

          reason("R3", fragment)
        end
      end

      # A question about the manual attributes nothing to it. A question that
      # also states what the manual says still does.
      def question_only?(fragment)
        body = fragment.to_s.strip
        (body.start_with?("¿") || body.end_with?("?")) && !body.match?(CLAIM_VERBS)
      end

      def attributes_source?(fragment, manufacturer)
        return true if fragment.match?(ATTRIBUTION_PATTERN)
        return false if manufacturer.blank?

        fragment.match?(/según\s+#{Regexp.escape(manufacturer)}/i)
      end

      def guard_reasons(text, quotes, locale)
        reasons = []
        body = text.to_s.strip
        if body.empty? || unavailable_marker?(body, locale)
          reasons << reason("R5", "empty_or_marker")
        elsif technical_without_citation?(body)
          reasons << reason("R5", "technical_without_citation")
        end
        missing = Array(quotes).reject { |quote| text.to_s.include?(quote_text(quote)) }
        reasons << reason("R5", "quote_removed") if missing.any?
        reasons
      end

      def unavailable_marker?(text, locale)
        return true if text.match?(/\bDATA_NOT_AVAILABLE\b/)

        missing = I18n.t("rag.data_not_available", locale: locale).to_s.strip
        uncited = I18n.t("rag.uncited_technical_answer", locale: locale).to_s.strip
        text == missing || text == uncited
      end

      def technical_without_citation?(text)
        !text.match?(CITATION_PATTERN) && AnswerSafetyProcessor.requires_evidence?(text)
      end

      def guard_signals(guards)
        Array(guards).filter_map do |guard|
          data = guard.respond_to?(:to_h) ? guard.to_h.stringify_keys : {}
          before = AnswerSafetyProcessor.fragments(data["before"])
          after = AnswerSafetyProcessor.fragments(data["after"])
          removed = before - after
          next if removed.empty?

          { "code" => "S3", "guard" => data["name"].to_s, "sentences" => removed }
        end
      end

      def content_signals(text, sources)
        signals = []
        AnswerSafetyProcessor.fragments(text).each do |fragment|
          numbers = fragment.scan(CITATION_PATTERN).flatten.map(&:to_i)
          next if numbers.empty?

          bodies = numbers.filter_map { |number| source_content(sources[number - 1]) }
          tokens(fragment).each do |token|
            next if bodies.any? { |body| body.include?(token) }

            signals << { "code" => "S1", "token" => token, "sources" => numbers }
          end
        end
        signals << { "code" => "S2", "questions" => text.to_s.count("?") }
        signals << { "code" => "S4", "list" => text.to_s.match?(LIST_PATTERN), "bold" => text.to_s.match?(BOLD_PATTERN) }
        signals
      end

      def tokens(fragment)
        found = fragment.scan(IDENTIFIER_TOKEN)
        found.concat(fragment.scan(AnswerSafetyProcessor::IDENTIFIER_PATTERN))
        found.concat(fragment.scan(AnswerSafetyProcessor::EVIDENCE_SENSITIVE_VALUE_PATTERN))
        found.map(&:to_s).uniq
      end

      def technician_quote?(quoted, texts)
        needle = normalized_body(quoted)
        return false if needle.blank?

        Array(texts).any? { |text| normalized_body(text).include?(needle) }
      end

      def aligned?(source, quoted)
        haystack = normalized_body(source)
        needle = quote_needle(quoted)
        return false if needle.blank?

        candidates = [ needle ]
        if needle.match?(/\A[[:alpha:]]/)
          flipped = needle.dup
          flipped[0] = flipped[0].swapcase
          candidates << flipped if flipped != needle
        end
        candidates.any? { |item| aligned_index(haystack, item) }
      end

      def aligned_index(haystack, needle)
        start = 0
        while (index = haystack.index(needle, start))
          before = index.zero? ? nil : haystack[index - 1]
          after = haystack[index + needle.length]
          return index if boundary?(before) && boundary?(after)

          start = index + 1
        end
        nil
      end

      def boundary?(char)
        char.nil? || !char.match?(/[[:alnum:]]/)
      end

      def fragment_match(fragment, quoted)
        needle = quote_needle(quoted)
        words = needle.split
        return nil if words.empty?

        parts = words.each_with_index.map do |word, index|
          body = Regexp.escape(word)
          next body unless index.zero? && word.match?(/\A[[:alpha:]]/)

          first = word[0]
          "[#{Regexp.escape(first.upcase)}#{Regexp.escape(first.downcase)}]" + Regexp.escape(word[1..] || "")
        end
        fragment.match(/#{parts.join('[[:space:]]+')}/)
      end

      def quote_needle(text)
        normalized_body(text).gsub(/\A[[:punct:]]+/, "").gsub(/[[:punct:]]+\z/, "").strip
      end

      def normalized_body(text)
        text.to_s.unicode_normalize(:nfc).gsub(/[[:space:]]+/, " ").gsub(LIST_MARKER, " ").gsub(/[[:space:]]+/, " ").strip
      end

      def marker_in?(text)
        body = text.to_s
        phrase_in?(body) || body.match?(marker_pattern)
      end

      def starts_with_marker?(text)
        body = text.to_s.sub(/\A[[:space:]]+/, "")
        CONDITION_PHRASES.any? { |phrase| body.match?(/\A#{Regexp.escape(phrase)}(?![[:alnum:]])/i) } ||
          body.match?(/\A(?:#{CONDITION_WORDS.map { |word| Regexp.escape(word) }.join('|')})(?![[:alnum:]])/i)
      end

      def phrase_in?(text)
        CONDITION_PHRASES.any? { |phrase| text.match?(/#{Regexp.escape(phrase)}/i) }
      end

      def marker_pattern
        @marker_pattern ||= /(?<![[:alnum:]])(?:#{CONDITION_WORDS.map { |word| Regexp.escape(word) }.join('|')})(?![[:alnum:]])/i
      end

      def source_hash(source)
        return {} if source.nil?
        return source if source.is_a?(Hash)

        source.respond_to?(:to_h) ? source.to_h : {}
      end

      def source_content(source)
        data = source_hash(source)
        (data["content"] || data[:content]).to_s
      end

      def source_number(source, offset)
        data = source_hash(source)
        number = data["index"] || data[:index]
        number.nil? ? offset + 1 : number.to_i
      end

      def quote_text(quote)
        data = source_hash(quote)
        (data["text"] || data[:text]).to_s
      end

      def reason(rule, detail)
        { "rule" => rule, "detail" => detail }
      end
    end
  end
end
