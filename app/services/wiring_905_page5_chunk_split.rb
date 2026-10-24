# frozen_string_literal: true

require "digest"

# Splits the one oversized body of Wiring - 905, PDF page 5, into three
# page-5 fragments. Local only: it does not read AWS, upload, or sync.
#
# The source is one specification sheet (drawing 811850E00, page 2/3). Its
# markdown table is repeated once per row as a SCHEMATIC_LABEL record, and
# that single object is what Titan Text Embeddings V2 rejected at 9048
# tokens. Each fragment keeps the sheet heading, the revision block, the
# rows of one position span, and the record that belongs to each row.
class Wiring905Page5ChunkSplit
  class Error < StandardError; end

  SOURCE_SHA256 = "c116762136452541d3df1116a810bccc6554178b95590f5817470b84d14e1d82"
  # BedrockRuntime count for this exact body on amazon.titan-embed-text-v2:0.
  OBSERVED_TITAN_TOKENS = 9048
  OBSERVED_BYTES = 22_548
  TITAN_INPUT_LIMIT = 8192
  # 6000 leaves the linear estimate 36% of headroom under the 8192 input limit.
  ESTIMATE_CEILING = 6000
  RECORD_MARKER = "# FIELD-SAFETY EVIDENCE RECORDS\n\n"
  LEAD = "The following component position numbers and their Russian-language descriptions are listed on this page. Exact text preserved verbatim:"
  FRAGMENT_LEAD = "The following component position numbers and their Russian-language descriptions are kept in this fragment of that page. Exact text preserved verbatim:"
  BASE_ALIASES = [ "811850E00", "СПЕЦИФИКАЦИЯ", "LCE", "KONE component list" ].freeze
  GROUPS = [
    { filename: "chunk_p5_1.txt", last: "106", span: "pos 82-106" },
    { filename: "chunk_p5_2.txt", last: "141:S1", span: "pos 112-141" },
    { filename: "chunk_p5_3.txt", last: "198", span: "pos 147-198" }
  ].freeze

  Row = Struct.new(:key, :description, :line, :record, keyword_init: true)

  def self.call(body:, sidecar:)
    new(body, sidecar).call
  end

  # UTF-8 bytes of this body scaled to the one Bedrock count of 9048.
  # Exact for the unchanged source. A fragment with the same mix of
  # Cyrillic labels and English record boilerplate should land near it.
  # chars/3.5 is the Claude fallback and undercounts this body
  # (5343 against 9048); it is not the ceiling used here.
  def self.estimate_titan_tokens(text)
    text.to_s.b.bytesize * OBSERVED_TITAN_TOKENS / OBSERVED_BYTES.to_f
  end

  def initialize(body, sidecar)
    @body = body.to_s.b
    @sidecar = sidecar.to_s.b.dup
  end

  def call
    digest = Digest::SHA256.hexdigest(@body)
    raise Error, "unexpected body #{digest}" unless digest == SOURCE_SHA256
    raise Error, "sidecar is empty" if @sidecar.empty?

    @body = @body.dup.force_encoding("UTF-8")
    raise Error, "body is not UTF-8" unless @body.valid_encoding?

    rows, extras = pair(parse_rows, parse_records)
    take_groups(rows).each_with_index.map do |(group, grouped_rows), index|
      records = grouped_rows.map(&:record)
      records.concat(extras) if index.zero?
      render(group, grouped_rows, records)
    end
  end

  private

  def parse_rows
    preamble, = split_body
    sections = preamble.split("\n\n", 2).last.to_s.split("\n\n")
    raise Error, "preamble has #{sections.size} blocks" unless sections.size == 6

    @heading = sections[0]
    @paragraph = sections[1]
    @revision = sections[2]
    @lead = sections[3]
    table = sections[4]
    @note = sections[5]
    raise Error, "heading is not S7" unless @heading.start_with?("S7 — DIAGRAM / SPECIFICATION PAGE 2/3")
    raise Error, "revision block missing" unless @revision.include?("Issue F: Pos. 101, 176, 732:1 added")
    raise Error, "lead sentence missing" unless @lead == LEAD
    raise Error, "note missing" unless @note.start_with?("Note: Positions 101, 176, and 732:1 were added in Issue F.")

    lines = table.lines(chomp: true)
    @table_header = lines[0].to_s
    @table_rule = lines[1].to_s
    raise Error, "table header missing" unless @table_header.include?("Pos. No.")
    raise Error, "table separator missing" unless @table_rule.include?("---")

    lines.drop(2).map { |line| row_from(line) }
  end

  def row_from(line)
    cells = line.split("|").map(&:strip).reject(&:empty?)
    raise Error, "table row is not two cells: #{line}" unless cells.size == 2

    Row.new(key: cells[0], description: cells[1], line: line)
  end

  def parse_records
    _, records_text = split_body
    records_text.split(/\n\n(?=FIELD_RECORD:\n)/).map do |block|
      text = block.sub(/\n+\z/, "")
      raise Error, "record is incomplete" unless text.start_with?("FIELD_RECORD:\n") && text.end_with?("END_FIELD_RECORD")

      text
    end
  end

  def split_body
    parts = @body.split(RECORD_MARKER, 2)
    raise Error, "field-record marker missing" unless parts.size == 2

    header, = parts[0].split("\n\n", 2)
    lines = header.to_s.lines(chomp: true)
    raise Error, "identity header is not three lines" unless lines.size == 3

    @document_line = lines[0]
    @source_line = lines[1]
    raise Error, "document line missing" unless @document_line == "[DOCUMENT: Wiring - 905.pdf]"
    raise Error, "source line missing" unless @source_line.start_with?("[SOURCE_URI: s3://multimodal-source-destination/bulk_uploads/3/2026-08-24/Wiring - 905.pdf]")

    parts
  end

  def pair(rows, records)
    by_key = {}
    extras = []
    records.each do |text|
      key = record_key(text)
      if key.nil?
        extras << text
      else
        raise Error, "duplicate record for #{key}" if by_key.key?(key)

        by_key[key] = text
      end
    end
    raise Error, "expected one revision record" unless extras.size == 1 && extras[0].include?("RECORD_TYPE: DOCUMENTATION_REQUIREMENT")

    rows.each do |row|
      text = by_key.delete(row.key)
      raise Error, "row #{row.key} has no record" if text.nil?

      action = text[/^ACTION: (.+)$/, 1].to_s
      raise Error, "record #{row.key} drops the printed description" unless action.include?(row.description)

      row.record = text
    end
    raise Error, "unpaired records #{by_key.keys.join(", ")}" if by_key.any?

    [ rows, extras ]
  end

  def record_key(text)
    action = text[/^ACTION: (.+)$/, 1].to_s
    return nil unless action.start_with?("Pos. ")

    action.split(" — ", 2).first.sub(/\APos\. /, "")
  end

  def take_groups(rows)
    remaining = rows.dup
    grouped = GROUPS.map do |group|
      taken = []
      while remaining.any? && taken.last&.key != group[:last]
        taken << remaining.shift
      end
      raise Error, "boundary #{group[:last]} missing" unless taken.last&.key == group[:last]

      [ group, taken ]
    end
    raise Error, "rows left after the last boundary" if remaining.any?

    grouped
  end

  def render(group, rows, records)
    body = [
      @document_line,
      @source_line,
      alias_line(group, rows),
      "",
      @heading,
      "",
      @paragraph,
      "",
      @revision,
      "",
      FRAGMENT_LEAD,
      "",
      table_for(rows),
      "",
      @note,
      "",
      "# FIELD-SAFETY EVIDENCE RECORDS",
      "",
      records.join("\n\n"),
      ""
    ].join("\n")
    estimate = self.class.estimate_titan_tokens(body)
    if estimate > ESTIMATE_CEILING
      raise Error, "#{group[:filename]} estimates #{estimate.round(1)} tokens"
    end

    {
      "filename" => group[:filename],
      "body" => body,
      "sidecar" => @sidecar,
      "bytes" => body.b.bytesize,
      "chars" => body.length,
      "words" => body.split(/\s+/).size,
      "titan_tokens_estimate" => estimate
    }
  end

  def table_for(rows)
    ([ @table_header, @table_rule ] + rows.map(&:line)).join("\n")
  end

  def alias_line(group, rows)
    keys = rows.map(&:key)
    names = BASE_ALIASES.dup
    names << group[:span]
    names << "ВЫКЛ. ДВЕРИ ШАХТЫ" if keys.include?("121")
    names << "ОГРАНИЧИТЕЛЬ СКОРОСТИ" if keys.include?("127")
    names << "LCEFCS LCEFOV" if keys.include?("197") && keys.include?("198")
    "[SEARCH_ALIASES: #{names.join(", ")}]"
  end
end
