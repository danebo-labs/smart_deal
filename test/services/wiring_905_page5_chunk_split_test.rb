# frozen_string_literal: true

require "test_helper"

class Wiring905Page5ChunkSplitTest < ActiveSupport::TestCase
  SPLIT = Wiring905Page5ChunkSplit
  BODY = Rails.root.join("test/fixtures/files/wiring_905/chunk_p5_1.txt")
  SIDECAR = Rails.root.join("test/fixtures/files/wiring_905/chunk_p5_1.txt.metadata.json")

  setup do
    @body = BODY.binread
    @sidecar = SIDECAR.binread
    @parts = SPLIT.call(body: @body, sidecar: @sidecar)
  end

  test "calibrates the unchanged body to the Bedrock token count" do
    assert_equal SPLIT::SOURCE_SHA256, Digest::SHA256.hexdigest(@body)
    assert_equal 22_548, @body.bytesize
    assert_in_delta 9048, SPLIT.estimate_titan_tokens(@body), 0.001
    claude = (@body.dup.force_encoding("UTF-8").length / 3.5).ceil

    assert_operator claude, :<, 9048
  end

  test "splits one sheet into three fragments that stay under the embedding ceiling" do
    assert_equal %w[chunk_p5_1.txt chunk_p5_2.txt chunk_p5_3.txt], @parts.pluck("filename")
    @parts.each do |part|
      assert_operator part["titan_tokens_estimate"], :<=, SPLIT::ESTIMATE_CEILING
      assert_operator part["titan_tokens_estimate"], :<, SPLIT::TITAN_INPUT_LIMIT
      assert_equal @sidecar, part["sidecar"]
      assert_includes part["body"], "[DOCUMENT: Wiring - 905.pdf]"
      assert_includes part["body"], "s3://multimodal-source-destination/bulk_uploads/3/2026-08-24/Wiring - 905.pdf"
      assert_includes part["body"], "S7 — DIAGRAM / SPECIFICATION PAGE 2/3"
      assert_includes part["body"], "Issue F: Pos. 101, 176, 732:1 added"
      assert_includes part["body"], "Meanings of position numbers not listed on this page are on other pages"
      assert_not_includes part["body"], SPLIT::LEAD
    end
  end

  test "keeps every row with its record and does not repeat a position" do
    source_rows = table_rows(@body)
    source_ids = @body.dup.force_encoding("UTF-8").scan(/^RECORD_ID: (FR-[0-9A-F]+)/).flatten

    assert_equal 56, source_rows.size
    assert_equal 57, source_ids.size
    assert_equal source_rows, @parts.flat_map { |part| table_rows(part["body"]) }
    assert_equal source_ids.tally, @parts.flat_map { |part| part["body"].scan(/^RECORD_ID: (FR-[0-9A-F]+)/).flatten }.tally

    seen = {}
    @parts.each do |part|
      table_rows(part["body"]).each do |key, description|
        assert_not seen.key?(key)
        seen[key] = true
        record = record_block(part["body"], key)
        assert_includes record, description
        assert_includes record, "END_FIELD_RECORD"
      end
    end
    assert_equal 1, @parts.sum { |part| part["body"].scan("RECORD_TYPE: DOCUMENTATION_REQUIREMENT").size }
    assert_includes @parts[0]["body"], "RECORD_TYPE: DOCUMENTATION_REQUIREMENT"
    assert_includes @parts[0]["body"], "pos 82-106"
    assert_includes @parts[1]["body"], "ВЫКЛ. ДВЕРИ ШАХТЫ"
    assert_includes @parts[1]["body"], "ОГРАНИЧИТЕЛЬ СКОРОСТИ"
    assert_not_includes @parts[0]["body"], "ВЫКЛ. ДВЕРИ ШАХТЫ"
    assert_includes @parts[2]["body"], "LCEFCS LCEFOV"
    assert_includes @parts[2]["body"], "(added Issue F)"
  end

  test "rejects a different body" do
    error = assert_raises(SPLIT::Error) { SPLIT.call(body: @body.b + "\n".b, sidecar: @sidecar) }
    assert_match(/unexpected body/, error.message)
  end

  private

  def table_rows(text)
    text.to_s.dup.force_encoding("UTF-8").each_line.filter_map do |line|
      next unless line.start_with?("| ")
      next if line.include?("Pos. No.") || line.include?("|---|")

      cells = line.split("|").map(&:strip).reject(&:empty?)
      [ cells[0], cells[1] ]
    end
  end

  def record_block(text, key)
    text.split(/^FIELD_RECORD:\n/).find { |block| block.include?("ACTION: Pos. #{key} —") }.to_s
  end
end
