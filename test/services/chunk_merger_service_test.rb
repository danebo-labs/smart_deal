# frozen_string_literal: true

require "test_helper"

class ChunkMergerServiceTest < ActiveSupport::TestCase
  DOC_NAME = "Orona Hydraulic Manual"
  ALIASES1 = %w[HPM-400 orona hydraulic]
  ALIASES2 = %w[HPM-400 pump specs]  # HPM-400 duplicated

  def page1_json
    {
      "document_name" => DOC_NAME,
      "aliases"       => ALIASES1,
      "chunks"        => [
        {
          "text" => "# S0 — DOCUMENT IDENTIFICATION\nContent page 1 chunk 0.",
          "page" => 1
        },
        {
          "text" => "# S4 — SAFETY SYSTEM\nContent page 1 chunk 1.",
          "page" => 1
        }
      ]
    }.to_json
  end

  def page3_json
    {
      "document_name" => DOC_NAME,
      "aliases"       => ALIASES2,
      "chunks"        => [
        {
          "text" => "# S6 — ELECTRICAL\nContent page 3 chunk 0.",
          "page" => 3
        }
      ]
    }.to_json
  end

  def page_results
    [
      { page_number: 1, text: page1_json,  usage: nil, model: "claude-sonnet-4-6" },
      { page_number: 3, text: page3_json,  usage: nil, model: "claude-opus-4-7"   }
    ]
  end

  test "merged JSON has expected document_name from page 1" do
    parsed = JSON.parse(ChunkMergerService.merge(page_results))
    assert_equal DOC_NAME, parsed["document_name"]
  end

  test "aliases are union of all pages with duplicates removed" do
    parsed = JSON.parse(ChunkMergerService.merge(page_results))
    combined = (ALIASES1 + ALIASES2).uniq
    assert_equal combined.sort, parsed["aliases"].sort
  end

  test "chunks from all pages are concatenated in page order" do
    parsed = JSON.parse(ChunkMergerService.merge(page_results))
    assert_equal 3, parsed["chunks"].count
    assert_includes parsed["chunks"][0]["text"], "chunk 0"
    assert_includes parsed["chunks"][2]["text"], "page 3 chunk 0"
  end

  test "preserves original page numbers (no renumbering)" do
    parsed = JSON.parse(ChunkMergerService.merge(page_results))
    assert_equal 1, parsed["chunks"][0]["page"]
    assert_equal 3, parsed["chunks"][2]["page"]
  end

  test "merges pages whose chunk[0] lacks **Document:**/**DOCUMENT_ALIASES:** body markers" do
    # Invariant: identity is Rails-injected (identity_header + sidecar); chunks need not carry markers.
    no_marker_results = [
      { page_number: 1, text: page1_json, usage: nil, model: "claude-sonnet-4-6" },
      { page_number: 3, text: page3_json, usage: nil, model: "claude-opus-4-7"   }
    ]
    parsed = JSON.parse(ChunkMergerService.merge(no_marker_results))
    assert_not_includes parsed["chunks"][0]["text"], "**Document:"
    assert_not_includes parsed["chunks"][0]["text"], "**DOCUMENT_ALIASES:"
    assert_equal DOC_NAME, parsed["document_name"]
    assert_equal 3, parsed["chunks"].count
  end

  # Canonical document_name rule (§2b): page 1 wins when present; min page_number otherwise.
  # This invariant applies to any multi-call split, not just PDF pages.
  test "canonical document_name: page 1 wins when pages disagree" do
    p1_json = { "document_name" => "Name From Page 1", "aliases" => %w[a], "chunks" => [ { "text" => "c1", "page" => 1 } ] }.to_json
    p2_json = { "document_name" => "Different Name",   "aliases" => %w[b], "chunks" => [ { "text" => "c2", "page" => 2 } ] }.to_json

    results = [
      { page_number: 1, text: p1_json, usage: nil, model: "claude-sonnet-4-6" },
      { page_number: 2, text: p2_json, usage: nil, model: "claude-sonnet-4-6" }
    ]
    parsed = JSON.parse(ChunkMergerService.merge(results))
    assert_equal "Name From Page 1", parsed["document_name"]
  end

  test "canonical document_name: min page_number used when page 1 absent" do
    p2_json = { "document_name" => "Name From Page 2", "aliases" => %w[a], "chunks" => [ { "text" => "c2", "page" => 2 } ] }.to_json
    p5_json = { "document_name" => "Name From Page 5", "aliases" => %w[b], "chunks" => [ { "text" => "c5", "page" => 5 } ] }.to_json

    results = [
      { page_number: 2, text: p2_json, usage: nil, model: "claude-opus-4-7" },
      { page_number: 5, text: p5_json, usage: nil, model: "claude-opus-4-7" }
    ]
    parsed = JSON.parse(ChunkMergerService.merge(results))
    assert_equal "Name From Page 2", parsed["document_name"]
  end

  test "handles page results in any input order by sorting on page_number" do
    shuffled = page_results.reverse
    parsed = JSON.parse(ChunkMergerService.merge(shuffled))
    # chunk[0] should still be page 1's first chunk
    assert_includes parsed["chunks"][0]["text"], "chunk 0"
    assert_equal 1, parsed["chunks"][0]["page"]
  end

  test "raises ArgumentError for empty page_results" do
    assert_raises(ArgumentError) { ChunkMergerService.merge([]) }
  end

  test "gracefully handles malformed JSON in one page" do
    bad_results = [
      { page_number: 1, text: page1_json,    usage: nil, model: "claude-opus-4-7" },
      { page_number: 2, text: "not json {{", usage: nil, model: "claude-opus-4-7" }
    ]
    # Should not raise — bad page produces empty chunks
    parsed = JSON.parse(ChunkMergerService.merge(bad_results))
    assert_equal DOC_NAME, parsed["document_name"]
    # Only page 1's chunks should be present (page 2 is malformed → empty)
    assert_equal 2, parsed["chunks"].count
  end
end
