# frozen_string_literal: true

module Rag
  # Local sections for one companion turn. The current catalog is nil unless
  # this process sets it. A nil catalog does not read S3 and does not expand.
  class CompanionDefinitionCatalog
    SECTION_HEADING = /\A\s*(\d+\.\d+)\s+(\S.*)\z/
    ENTRY_HEADING = /\A\s*(\d+)\.-\s+(\S.*)\z/
    PAREN_IDS = /\((\d+(?:\s*,\s*\d+)*)\)/

    class << self
      def current
        Thread.current[:companion_definition_catalog]
      end

      def current=(catalog)
        Thread.current[:companion_definition_catalog] = catalog
      end

      def with(catalog)
        previous = current
        self.current = catalog
        yield
      ensure
        self.current = previous
      end

      def from_pages(pages)
        new(pages)
      end
    end

    def initialize(pages)
      @pages = Array(pages)
    end

    def sections
      @sections ||= @pages.flat_map { |page| parse_page(page) }
    end

    def page(document_key, filename)
      @pages.find { |raw|
        data = raw.to_h.stringify_keys
        data["document_key"].to_s == document_key.to_s && data["filename"].to_s == filename.to_s
      }
    end

    private

    def parse_page(page)
      data = page.to_h.stringify_keys
      lines = data["text"].to_s.lines.map { |line| line.delete_suffix("\n") }
      blocks = []
      current = nil
      parent = nil
      lines.each do |line|
        heading = heading_for(line)
        if heading
          blocks << finish(current) if current
          parent = { "line" => heading["line"], "number" => heading["number"] } if heading["kind"] == "section"
          heading["parent"] = heading["kind"] == "entry" ? parent : nil
          current = heading
        elsif current
          current["body_lines"] << line
        end
      end
      blocks << finish(current) if current
      blocks.each { |block| stamp(block, data) }
      blocks
    end

    def heading_for(line)
      if (match = line.match(SECTION_HEADING))
        heading("section", match[1], line, match[2])
      elsif (match = line.match(ENTRY_HEADING))
        heading("entry", match[1], line, match[2])
      end
    end

    def heading(kind, number, line, title)
      {
        "kind" => kind,
        "number" => number,
        "line" => line.strip,
        "title" => title.to_s.strip,
        "body_lines" => [],
        "principal_ids" => principal_ids(kind, number, line)
      }
    end

    # A list of several numbers is the parent section, not a definition of
    # each number. The entry heading, or a heading with one parenthetical
    # number, is the definition label.
    def principal_ids(kind, number, line)
      return [ number.to_i ] if kind == "entry"

      ids = line.to_s.scan(PAREN_IDS).flat_map { |group| group.first.split(/\s*,\s*/) }.map(&:to_i)
      ids.size == 1 ? ids : []
    end

    def finish(heading)
      heading["body"] = heading.delete("body_lines").join("\n").strip
      heading
    end

    def stamp(block, page)
      block["document_key"] = page["document_key"].to_s
      block["page"] = page["page"]
      block["name"] = page["name"].to_s
      block["filename"] = page["filename"].to_s
      block["provenance"] = page["provenance"].to_s
    end
  end
end
