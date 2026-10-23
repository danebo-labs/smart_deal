# frozen_string_literal: true

module Rag
  # Numbered statements of the companion sources. A bullet item governs the
  # dash lines that follow it without other text in between; those are its
  # steps. A page mark between two steps does not separate them. A sentence, a table row, a
  # warning, and a conflict note are statements of their own. A whole line that
  # carries an extraction marker, or that starts with [NOTA_EXTRACCION], is one
  # extraction note: it is not split into sentences and it is not document text.
  # A manufacturer line that only begins with «Nota:» stays document text.
  # The text of a statement is a literal piece of its source. Reference-only
  # sources and record blocks give no statements.
  class CompanionStatements
    Statement = Data.define(:id, :source, :kind, :text, :section, :item, :page) do
      def step?
        kind == "step"
      end
    end

    SECTION_LINE = /\A\d{1,2}(?:\.\d{1,2})+\.?\s+\p{L}/
    ENTRY_LINE = /\A\d{1,3}\.-\s*\S/
    ITEM_LINE = /\A[•●▪]\s*(?<text>\S.*)\z/
    DASH_LINE = /\A[–—-]\s+(?<text>\S.*)\z/
    TABLE_RULE = /\A\|[\s\-|:]+\|\z/
    PAGE_MARK = /\A\[PDF_PAGE:\s*(\d+)\]\z/
    CONFLICT_LINE = /\A\[CONFLICTO_DOCUMENTAL\b/
    EXTRACTOR_NOTE_LINE = /\A\[NOTA_EXTRACCION\b/
    WARNING_LINE = /\A(?:IMPORTANTE|ATENCI[ÓO]N|ADVERTENCIA|PRECAUCI[ÓO]N|PELIGRO|WARNING|CAUTION|DANGER)\b/i
    HEADER_LINE = /\A(?:\[(?:PRINTED_PAGE|DOCUMENT|SOURCE_URI|SEARCH_ALIASES|TRANSCRIPCI[ÓO]N_VISUAL_LOCAL)\b|THIS JOB'S EQUIPMENT:|#{Regexp.escape(DocumentIdentityScope::OTHER_EQUIPMENT_PREFIX)})/
    EXTRACTION_MARKER = /\b(?:DATA_NOT_AVAILABLE|REQUIRES_FIELD_VERIFICATION)\b/
    SENTENCE_SPLIT = /(?<=[.!?])\s+(?=[[:upper:]¿¡«"(])/

    attr_reader :statements

    def self.parse(chunks)
      new(chunks)
    end

    def initialize(chunks)
      @statements = []
      Array(chunks).each_with_index do |chunk, index|
        next if DocumentIdentityScope.reference_only_chunk?(chunk)

        parse_chunk(chunk, index + 1)
      end
    end

    def find(id)
      @index ||= @statements.index_by(&:id)
      @index[id.to_s]
    end

    def by_source(source)
      @statements.select { |statement| statement.source == source }
    end

    private

    def parse_chunk(chunk, source)
      metadata = (chunk[:metadata] || chunk["metadata"]).to_h.stringify_keys
      content = (chunk[:content] || chunk["content"]).to_s
      page = metadata["page_number"].presence
      section = nil
      item = nil
      steps_open = false
      number = 0
      DocumentIdentityScope.omit_terminal_evidence_records(content).lines.each do |raw|
        line = raw.strip
        next if line.empty?

        if (mark = line.match(PAGE_MARK))
          page = mark[1]
          next
        end
        next if line.match?(HEADER_LINE) || line.match?(TABLE_RULE)

        if line.match?(CONFLICT_LINE)
          number = add(source, number, "conflict", line, section, item, page)
          next
        end
        if line.match?(EXTRACTOR_NOTE_LINE) || line.match?(EXTRACTION_MARKER)
          steps_open = false
          number = add(source, number, "extraction_note", line, section, item, page)
          next
        end
        if line.match?(SECTION_LINE) || line.match?(ENTRY_LINE)
          section = line
          item = nil
          steps_open = false
          number = add(source, number, "heading", line, section, item, page)
          next
        end
        if (bullet = line.match(ITEM_LINE))
          item = bullet[:text]
          steps_open = true
          number = add(source, number, "item", item, section, item, page)
          next
        end
        if (dash = line.match(DASH_LINE))
          number = add(source, number, steps_open ? "step" : "text", dash[:text], section, item, page)
          next
        end
        steps_open = false
        if line.start_with?("|")
          number = add(source, number, "text", line, section, item, page)
          next
        end
        line.split(SENTENCE_SPLIT).each do |sentence|
          kind = sentence.match?(WARNING_LINE) ? "warning" : "text"
          number = add(source, number, kind, sentence.strip, section, item, page)
        end
      end
    end

    def add(source, number, kind, text, section, item, page)
      return number if text.blank?

      kind = "extraction_note" if kind != "conflict" && text.match?(EXTRACTION_MARKER)
      number += 1
      @statements << Statement.new(
        id: "S#{source}.#{number}", source: source, kind: kind, text: text,
        section: section, item: item, page: page
      )
      number
    end
  end
end
