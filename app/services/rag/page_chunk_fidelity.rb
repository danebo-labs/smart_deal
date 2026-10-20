# frozen_string_literal: true

module Rag
  # Restores a chunk body from the page text it claims to represent.
  # Invented headings and notes drop out. A page that opens mid-section keeps
  # that opening when the chunk's first aligned paragraph is still near it.
  # An example is not rendered again as a general field action.
  # The caller supplies the page text. This class does not read the PDF.
  class PageChunkFidelity
    PREFIX_LIMIT = 600
    ALIGN = 0.72
    EXAMPLE_MARK = /ejemplo\s*:|example\s*:/i

    def self.correct(chunk_text, page_text)
      page = page_text.to_s.strip
      return chunk_text.to_s if page.blank?

      header, rest = split_header(chunk_text.to_s)
      narrative, records = split_records(rest)
      kept = restore_lines(narrative, page)
      prefix = opening_prefix(page, kept)
      body = [ prefix, kept ].compact_blank.join("\n\n")
      return chunk_text.to_s if body.blank?

      pieces = [ header.strip, body ]
      kept_records = filter_record_block(records, page)
      pieces << "# FIELD-SAFETY EVIDENCE RECORDS\n\n#{kept_records}" if kept_records.present?
      "#{pieces.compact_blank.join("\n\n")}\n"
    end

    def self.rewrite_search_results(prompt, pages)
      list = Array(pages).map { |page| page.to_s }.compact_blank
      prompt.to_s.gsub(%r{(<content>\n)(.*?)(\n</content>)}m) do
        prefix = Regexp.last_match(1)
        body = Regexp.last_match(2)
        suffix = Regexp.last_match(3)
        page = best_page(body, list)
        replacement = page ? correct(body, page).sub(/\A\n+/, "").sub(/\s+\z/, "") : body
        "#{prefix}#{replacement}#{suffix}"
      end
    end

    # True when a field-record action restates an example from the narrative
    # and drops the word that marks it as an example.
    def self.promoted_example?(record, narrative)
      values = record.respond_to?(:deep_stringify_keys) ? record.deep_stringify_keys : {}
      action = values["a"].to_s
      evidence = values["ev"].to_s
      return false if action.match?(EXAMPLE_MARK) || evidence.match?(EXAMPLE_MARK)

      spans = example_spans(narrative)
      return false if spans.empty?

      claim = "#{action} #{evidence}"
      tokens(claim).size >= 6 && spans.any? { |span| recall(claim, span) >= 0.55 }
    end

    def self.strip_running_matter(text)
      text.to_s.lines.reject { |line|
        stripped = line.strip.delete("\f")
        stripped.match?(/\A(?:INSTRUCCIONES|DOC-[A-Z0-9.]{6,}|Versi[oó]n:\s*\S+)\z/i) ||
          stripped.match?(/\bwww\.\S+/i) ||
          stripped.match?(/\APág\.\s*\d/i) ||
          stripped.match?(/\AMódulo electrónico\b/i)
      }.join.gsub(/\n{3,}/, "\n\n").strip
    end

    def self.best_page(body, pages)
      scored = pages.map { |page| [ overlap_score(body, page), page ] }
      score, page = scored.max_by { |row| row[0] }
      score.to_i >= 2 ? page : nil
    end
    private_class_method :best_page

    def self.overlap_score(body, page)
      words = tokens(body)
      page_norm = norm(page)
      words.each_cons(8).count { |window| page_norm.include?(window.join(" ")) }
    end
    private_class_method :overlap_score

    def self.restore_lines(narrative, page)
      page_norm = norm(page)
      sentences = page_sentences(page)
      narrative.to_s.lines.flat_map { |line|
        flatten(line).split(/(?<=[.!?])\s+/)
      }.filter_map { |sentence|
        stripped = sentence.strip
        next if stripped.empty?
        next unless aligned_line?(stripped, page_norm)

        matching_sentence(stripped, sentences) || stripped
      }.uniq.join("\n")
    end
    private_class_method :restore_lines

    def self.aligned_line?(line, page_norm)
      significant = tokens(line).select { |word| word.length >= 4 }
      return false if significant.empty?

      hits = significant.count { |word| page_norm.match?(/\b#{Regexp.escape(word)}\b/) }
      hits.to_f / significant.size >= ALIGN
    end
    private_class_method :aligned_line?

    def self.matching_sentence(line, sentences)
      best = sentences.max_by { |sentence| recall(line, sentence) }
      return nil if best.nil? || recall(line, best) < ALIGN

      line_count = tokens(line).size
      sentence_count = tokens(best).size
      return nil if sentence_count > (line_count * 1.8) || line_count > (sentence_count * 1.8)

      best
    end
    private_class_method :matching_sentence

    def self.page_sentences(page)
      paragraphs(page).flat_map { |paragraph|
        flatten(paragraph).split(/(?<=[.!?])\s+/)
      }.map(&:strip).reject(&:empty?)
    end
    private_class_method :page_sentences

    def self.opening_prefix(page, kept)
      return "" if kept.blank?

      kept_norm = norm(kept)
      units = paragraphs(page).map { |paragraph| flatten(paragraph) }
      index = units.index { |unit| aligned_line?(unit, kept_norm) }
      return "" if index.nil? || index.zero?

      offset = units[0...index].sum(&:length)
      return "" if offset > PREFIX_LIMIT

      units[0...index].reject { |unit| kept_norm.include?(norm(unit)) }.join("\n\n")
    end
    private_class_method :opening_prefix

    def self.filter_record_block(block, page)
      parts = block.to_s.split(/(?=^FIELD_RECORD:)/).map(&:strip).reject(&:empty?)
      parts.select { |part| keep_rendered_record?(part, page) }.join("\n\n")
    end
    private_class_method :filter_record_block

    def self.keep_rendered_record?(part, page)
      evidence = part[/^EVIDENCE:\s*(.+)$/, 1].to_s
      action = part[/^ACTION:\s*(.+)$/, 1].to_s
      normalized = norm(evidence)
      return false if normalized.blank? || norm(page).exclude?(normalized)
      return false if evidence_inside_example?(evidence, page) && !action.match?(EXAMPLE_MARK)

      true
    end
    private_class_method :keep_rendered_record?

    def self.evidence_inside_example?(evidence, page)
      normalized = norm(evidence)
      paragraphs(page).any? { |paragraph|
        paragraph.match?(EXAMPLE_MARK) && norm(paragraph).include?(normalized)
      }
    end
    private_class_method :evidence_inside_example?

    def self.example_spans(narrative)
      parts = narrative.to_s.split(/(?<=[.!?])\s+/)
      parts.each_with_index.filter_map { |part, index|
        next unless part.match?(EXAMPLE_MARK)

        [ part, parts[index + 1] ].compact.join(" ")
      }
    end
    private_class_method :example_spans

    def self.split_header(text)
      lines = text.lines
      header = []
      body = []
      seen = false
      lines.each do |line|
        if !seen && (line.strip.empty? || line.match?(/\A(?:THIS JOB'S EQUIPMENT:|\[DOCUMENT:|\[SOURCE_URI:|\[SEARCH_ALIASES:)/))
          header << line
        else
          seen = true
          body << line
        end
      end
      [ header.join, body.join ]
    end
    private_class_method :split_header

    def self.split_records(text)
      marker = "# FIELD-SAFETY EVIDENCE RECORDS"
      narrative, _, records = text.partition(marker)
      [ narrative, records ]
    end
    private_class_method :split_records

    def self.paragraphs(text)
      text.to_s.split(/\n\s*\n/).map(&:strip).reject(&:empty?)
    end
    private_class_method :paragraphs

    def self.flatten(text)
      text.to_s.gsub(/\s+/, " ").strip
    end
    private_class_method :flatten

    def self.recall(left, right)
      words = tokens(left)
      return 0.0 if words.empty?

      other = tokens(right)
      words.count { |word| other.include?(word) }.to_f / words.size
    end
    private_class_method :recall

    def self.tokens(text)
      norm(text).split
    end
    private_class_method :tokens

    def self.norm(text)
      I18n.transliterate(text.to_s).downcase.gsub(/[^a-z0-9]+/, " ").squeeze(" ").strip
    end
    private_class_method :norm
  end
end
