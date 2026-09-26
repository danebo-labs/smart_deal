# frozen_string_literal: true

module Rag
  # Drops unit-bearing values the retrieved chunks, the question, and this
  # turn's photo block do not contain. One pass. No second model call.
  class SourceFidelityGuard
    PHOTO_EVIDENCE_HEADING = "## Photo Evidence (this turn)"
    LIST_ITEM = /\A\s*(?:[-*•]|\d{1,2}[.)])\s+\S/.freeze
    # A period ends a sentence only before a new sentence or the end of the text.
    # "p. 4" and "aprox. 12" stay inside the sentence that contains them.
    SENTENCE_BOUNDARY = /[\n!?]|\.(?=\s+[[:upper:]¿¡]|\s*\z)/.freeze
    NUMBER_SRC = '\d+(?:[.,]\d+)?'
    # Ampere is only the capital A. A lowercase "a" is the Spanish preposition.
    UNIT_SRC = '(?:V(?:AC|DC|CC|CA)?|N\u00B7M|NM|BAR|MM|CM|[°º]C|HZ|(?-i:A)|%|vueltas|turns)'
    # Lowercase "a" is a range word ("3 a 5 mm"). Capital A stays the ampere unit.
    RANGE_SEPARATOR_SRC = '(?:–|-|/|±|(?-i:\ba\b)|\by\b|\bto\b|\band\b|\bhasta\b)'
    PAIR_PATTERN = /
      (?<![[:alnum:].,])
      (#{NUMBER_SRC})
      \s*
      (#{UNIT_SRC})
      (?![[:alnum:]])
    /ix.freeze
    RANGE_PATTERN = /
      (?<![[:alnum:].,])
      #{NUMBER_SRC}
      (?:
        \s*#{RANGE_SEPARATOR_SRC}\s*
        #{NUMBER_SRC}
      )+
      \s*
      (#{UNIT_SRC})
      (?![[:alnum:]])
    /ix.freeze
    UNIT_ALIASES = {
      "VDC" => "V",
      "VAC" => "V",
      "VCC" => "V",
      "VCA" => "V",
      "N\u00B7M" => "NM",
      "\u00BAC" => "\u00B0C"
    }.freeze

    def self.call(answer:, evidence_texts:, allowed_texts:, locale:, correlation_id: nil)
      new(
        answer: answer,
        evidence_texts: evidence_texts,
        allowed_texts: allowed_texts,
        locale: locale,
        correlation_id: correlation_id
      ).call
    end

    def self.evidence_texts(citations)
      Array(citations).filter_map do |citation|
        body = citation_body(citation)
        body.to_s.presence
      end
    end

    def self.allowed_texts(question:, effective_question:, session_context:)
      [ question, effective_question, photo_evidence_block(session_context) ].compact_blank
    end

    def self.citation_body(citation)
      return citation if citation.is_a?(String)
      return nil unless citation.respond_to?(:[])

      citation[:content] || citation["content"] || citation[:text] || citation["text"]
    end

    def self.photo_evidence_block(session_context)
      source = session_context.to_s
      start = source.index(PHOTO_EVIDENCE_HEADING)
      return nil unless start

      rest = source[start..]
      finish = rest.index(/\n## /, 1)
      finish ? rest[0...finish] : rest
    end

    def initialize(answer:, evidence_texts:, allowed_texts:, locale:, correlation_id:)
      @answer = answer.to_s
      @evidence_texts = Array(evidence_texts).map(&:to_s)
      @allowed_texts = Array(allowed_texts)
      @locale = locale
      @correlation_id = correlation_id
    end

    def call
      if @evidence_texts.all?(&:blank?)
        log(skipped: "no_evidence")
        return { answer: @answer, removed: 0 }
      end

      supported = pairs_in(@evidence_texts + @allowed_texts)
      ranges = []
      @answer.to_enum(:scan, PAIR_PATTERN).each do
        match = Regexp.last_match
        pair = normalize_pair(match[1], match[2])
        next if supported.include?(pair)

        ranges << removal_range(@answer, match.begin(0), match.end(0))
      end
      removed = ranges.size
      return { answer: @answer, removed: 0 } if removed.zero?

      answer = delete_ranges(@answer, ranges)
      answer = append_notice(answer)
      log(removed: removed)
      { answer: answer, removed: removed }
    end

    private

    def pairs_in(texts)
      texts.flat_map { |text| pairs(text) }.to_set
    end

    def pairs(text)
      source = text.to_s
      found = source.scan(PAIR_PATTERN).map { |number, unit| normalize_pair(number, unit) }
      found.concat(range_pairs(source))
    end

    # "220/380 VAC" and "3 y 5 mm" support every number in the expression, not only the last.
    def range_pairs(text)
      found = []
      text.to_s.scan(RANGE_PATTERN) do
        match = Regexp.last_match
        unit = match[1]
        match[0].scan(/\d+(?:[.,]\d+)?/).each do |number|
          found << normalize_pair(number, unit)
        end
      end
      found
    end

    def normalize_pair(number, unit)
      key = unit.to_s.upcase
      [ normalize_number(number), UNIT_ALIASES.fetch(key, key) ]
    end

    def normalize_number(number)
      value = number.to_s.tr(",", ".")
      return value unless value.include?(".")

      integer, fraction = value.split(".", 2)
      fraction = fraction.sub(/0+\z/, "")
      fraction.empty? ? integer : "#{integer}.#{fraction}"
    end

    def removal_range(text, from, to)
      list_line_range(text, from) || sentence_range(text, from, to)
    end

    def list_line_range(text, from)
      line_start = text.rindex("\n", from - 1)
      line_start = line_start ? line_start + 1 : 0
      line_end = text.index("\n", from) || text.length
      return nil unless text[line_start...line_end].match?(LIST_ITEM)

      finish = line_end < text.length ? line_end + 1 : line_end
      line_start...finish
    end

    def sentence_range(text, from, to)
      left = from.zero? ? nil : text.rindex(SENTENCE_BOUNDARY, from - 1)
      start_at = left.nil? ? 0 : boundary_end(text, left)
      right = text.index(SENTENCE_BOUNDARY, to)
      finish = if right.nil?
        text.length
      elsif text[right] == "."
        right + 1
      else
        right
      end
      finish += 1 if finish < text.length && text[finish] == " "
      start_at...finish
    end

    def boundary_end(text, index)
      pos = index + 1
      if text[index] == "."
        pos += 1 while pos < text.length && text[pos] == " "
        return pos
      end

      pos += 1 while pos < text.length && text[pos].match?(/[\n!?]/)
      pos += 1 while pos < text.length && text[pos] == " "
      pos
    end

    def delete_ranges(text, ranges)
      merged = merge_ranges(ranges)
      edited = text.dup
      merged.sort_by { |range| -range.begin }.each { |range| edited[range] = "" }
      edited.gsub(/[ ]{2,}/, " ").gsub(/\n{3,}/, "\n\n").strip
    end

    def merge_ranges(ranges)
      ordered = ranges.sort_by(&:begin)
      merged = [ ordered.first ]
      ordered.drop(1).each do |range|
        last = merged.last
        if range.begin <= last.end
          merged[-1] = last.begin...[ last.end, range.end ].max
        else
          merged << range
        end
      end
      merged
    end

    def append_notice(text)
      notice = I18n.t("rag.unsupported_value_removed", locale: @locale)
      return notice if text.blank?
      return text if text.include?(notice)

      "#{text}\n\n#{notice}"
    end

    def log(removed: nil, skipped: nil)
      payload = { event: "source_fidelity_guard", correlation_id: @correlation_id }
      payload[:removed] = removed unless removed.nil?
      payload[:skipped] = skipped if skipped
      Rails.logger.info(payload.to_json)
    end
  end
end
