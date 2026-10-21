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

    # Lines printed on at least half of the pages, and on three or more.
    # The caller passes one document's page texts. A folio is not this set:
    # its digits change on every page, and FOLIO_LINE strips it on its own.
    def self.running_matter_lines(page_texts)
      grouped = Hash.new { |lines, line| lines[line] = [] }
      texts = normalize_page_map(page_texts)
      texts.each do |number, text|
        text.to_s.lines.map { |line| collapse_line(line) }.reject(&:empty?).uniq.each do |line|
          next if folio_line?(line)

          grouped[line] << number
        end
      end
      return [] if texts.empty?

      half = texts.size / 2.0
      grouped.select { |_line, pages| pages.size >= 3 && pages.size >= half }.keys.sort
    end

    # Four local measures. Nothing here reads a PDF or writes a chunk.
    # Precision is the pre-merge narrative against its own page. Recall of the
    # opening and of numeric literals uses recall_chunks when the merge has
    # moved text; otherwise it uses chunks. A thin or blank text layer is not
    # verifiable. Presence never verifies table column order.
    def self.assess_coverage(page_texts:, chunks:, discards: {}, page_count: nil, recall_chunks: nil, anchor_page: nil)
      texts = normalize_page_map(page_texts)
      bodies = normalize_coverage_chunks(chunks)
      recalled = recall_chunks.nil? ? bodies : normalize_coverage_chunks(recall_chunks)
      dropped = normalize_discards(discards)
      running = running_matter_lines(texts)
      numbers = coverage_page_numbers(texts, bodies, dropped, page_count)
      anchor = anchor_page&.to_i
      anchor = bodies.pluck(:page).min if anchor.nil? || anchor <= 0

      pages = numbers.index_with { |number|
        assess_page(
          number,
          text: texts[number].to_s,
          chunks: bodies,
          recalled: recalled,
          discarded: dropped.key?(number),
          running: running,
          anchor: anchor
        )
      }
      { running_lines: running, pages: pages }
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

    # Below this, the narrative was not written from the page. A paraphrase
    # that still uses the page's words stays above it.
    PRECISION_FLOOR = 0.40
    # A text layer with fewer significant words cannot support alignment.
    # Blank and diagram-title pages are not verifiable, same as a scan.
    MIN_TEXT_TOKENS = 12
    OPENING_WINDOW = 8
    OPENING_PREFIX = 40
    OPENING_MIN_SIGNIFICANT = 4
    FOLIO_LINE = /(?:p[aá]g(?:ina)?|page)\.?\s*\d{1,4}\s*(?:\/|de|of)\s*\d{1,4}/i
    LITERAL_PATTERN = /#\d+|\d+,\d+|\d+\.\d+|\d+\s*V\b/i

    def self.assess_page(number, text:, chunks:, recalled:, discarded:, running:, anchor:)
      stripped = strip_furniture(text, running)
      verifiable = significant_count(stripped) >= MIN_TEXT_TOKENS
      narratives = precision_narratives(chunks, number, anchor)
      precision = verifiable ? precision_ratio(narratives.join("\n"), text) : nil
      recall = recall_texts(recalled, number).join("\n")
      {
        accounted: chunks.any? { |chunk| chunk[:page] == number } || discarded,
        discarded: discarded,
        verifiable: verifiable,
        precision: precision,
        precision_low: verifiable && !precision.nil? && precision < PRECISION_FLOOR,
        added_lines: verifiable ? added_lines_for(narratives, norm(text), running) : [],
        opening_present: verifiable ? opening_present?(stripped, recall) : nil,
        missing_numbers: verifiable ? missing_literals(stripped, recall) : nil,
        layout_order_verified: false
      }
    end
    private_class_method :assess_page

    def self.coverage_page_numbers(texts, chunks, discards, page_count)
      if page_count.to_i.positive?
        (1..page_count.to_i).to_a
      else
        (texts.keys + chunks.pluck(:page) + discards.keys).uniq.sort
      end
    end
    private_class_method :coverage_page_numbers

    def self.normalize_page_map(page_texts)
      Array(page_texts).each_with_object({}) do |(number, text), map|
        map[number.to_i] = text.to_s
      end
    end
    private_class_method :normalize_page_map

    def self.normalize_coverage_chunks(chunks)
      Array(chunks).filter_map do |chunk|
        next if chunk.blank?

        values = chunk.respond_to?(:deep_stringify_keys) ? chunk.deep_stringify_keys : {}
        source = values["source_pdf_page"]
        {
          page: values["page"].to_i,
          text: values["text"].to_s,
          source_pdf_page: source.present? ? source.to_i : nil
        }
      end
    end
    private_class_method :normalize_coverage_chunks

    def self.normalize_discards(discards)
      Array(discards).each_with_object({}) do |(number, reason), map|
        map[number.to_i] = reason
      end
    end
    private_class_method :normalize_discards

    def self.precision_narratives(chunks, page, anchor)
      chunks.filter_map do |chunk|
        next unless chunk[:page] == page
        next if page == anchor && s0_narrative?(chunk[:text])

        narrative_text(chunk[:text])
      end
    end
    private_class_method :precision_narratives

    def self.s0_narrative?(text)
      narrative = narrative_text(text)
      narrative.match?(/\bS0\b/) && narrative.match?(/DOCUMENT IDENTIFICATION/i)
    end
    private_class_method :s0_narrative?

    def self.narrative_text(text)
      _header, body = split_header(text.to_s)
      narrative, _records = split_records(body)
      narrative
    end
    private_class_method :narrative_text

    def self.precision_ratio(narrative, page_text)
      words = tokens(narrative).select { |word| word.length >= 4 }
      return nil if words.empty?

      page_norm = norm(page_text)
      hits = words.count { |word| page_norm.match?(/\b#{Regexp.escape(word)}\b/) }
      hits.to_f / words.size
    end
    private_class_method :precision_ratio

    def self.added_lines_for(narratives, page_norm, running)
      narratives.flat_map(&:lines).filter_map do |line|
        stripped = collapse_line(line)
        next if stripped.empty? || folio_line?(stripped) || running.include?(stripped)
        next if tokens(stripped).none? { |word| word.length >= 4 }
        next if aligned_line?(stripped, page_norm)

        stripped
      end
    end
    private_class_method :added_lines_for

    def self.opening_present?(stripped_page, recall_text)
      paragraph = opening_paragraph(stripped_page)
      return nil if paragraph.nil?

      words = tokens(paragraph).first(OPENING_PREFIX)
      return nil if words.size < 4

      window = [ OPENING_WINDOW, words.size ].min
      hay = norm(recall_text)
      words.each_cons(window).any? { |gram| hay.include?(gram.join(" ")) }
    end
    private_class_method :opening_present?

    def self.opening_paragraph(text)
      paragraphs(text).find { |paragraph|
        tokens(paragraph).count { |word| word.length >= 4 } >= OPENING_MIN_SIGNIFICANT
      }
    end
    private_class_method :opening_paragraph

    def self.missing_literals(stripped_page, recall_text)
      number_literals(stripped_page).reject { |literal| literal_present?(literal, recall_text) }
    end
    private_class_method :missing_literals

    def self.number_literals(text)
      seen = {}
      text.to_s.scan(LITERAL_PATTERN).filter_map do |literal|
        cleaned = literal.to_s.strip.gsub(/\s+/, " ")
        key = compact_form(cleaned)
        next if key.blank? || seen[key]

        seen[key] = true
        cleaned
      end
    end
    private_class_method :number_literals

    def self.literal_present?(literal, text)
      needle = compact_form(literal)
      return false if needle.blank?

      escaped = Regexp.escape(needle)
      pattern = needle.match?(/\A#?\d/) ? /(?<!\d)#{escaped}(?!\d)/ : /#{escaped}/
      compact_form(text).match?(pattern)
    end
    private_class_method :literal_present?

    def self.compact_form(text)
      I18n.transliterate(text.to_s).downcase.gsub(/\s+/, "")
    end
    private_class_method :compact_form

    def self.recall_texts(chunks, page)
      chunks.flat_map do |chunk|
        pieces = []
        pieces << chunk[:text] if chunk[:page] == page || chunk[:source_pdf_page] == page
        pieces.concat(marked_regions(chunk[:text], page))
        pieces
      end
    end
    private_class_method :recall_texts

    def self.marked_regions(text, page)
      text.to_s.scan(/\[PDF_PAGE:\s*#{page.to_i}\](.*?)(?=\[PDF_PAGE:|\z)/m).flatten
    end
    private_class_method :marked_regions

    def self.strip_furniture(text, running)
      text.to_s.lines.reject { |line|
        stripped = collapse_line(line)
        next false if stripped.empty?

        folio_line?(stripped) || running.include?(stripped)
      }.join
    end
    private_class_method :strip_furniture

    def self.folio_line?(line)
      collapse_line(line).match?(FOLIO_LINE)
    end
    private_class_method :folio_line?

    def self.collapse_line(line)
      line.to_s.strip.delete("\f").gsub(/\s+/, " ")
    end
    private_class_method :collapse_line

    def self.significant_count(text)
      tokens(text).count { |word| word.length >= 4 }
    end
    private_class_method :significant_count
  end
end
