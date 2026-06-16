# frozen_string_literal: true

require "test_helper"

class ChunkMergerServiceTest < ActiveSupport::TestCase
  DOC_NAME = "Orona Hydraulic Manual"
  ALIASES1 = %w[HPM-400 orona hydraulic]
  ALIASES2 = %w[HPM-400 pump specs]  # HPM-400 duplicated

  PAGE1_SUMMARY         = "Parece un manual de hidráulica Orona — cubre seguridad y puesta en marcha."
  PAGE1_COMPANION_OFFER = "Dime qué necesitas saber, cualquier pregunta está bien."

  def page1_json(summary: PAGE1_SUMMARY, companion_offer: PAGE1_COMPANION_OFFER)
    {
      "document_name"   => DOC_NAME,
      "aliases"         => ALIASES1,
      "summary"         => summary,
      "companion_offer" => companion_offer,
      "chunks"          => [
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
      "summary"       => "Page 3 summary — should not be used.",
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

  test "document aliases are union of all pages with duplicates removed" do
    parsed = JSON.parse(ChunkMergerService.merge(page_results))
    combined = (ALIASES1 + ALIASES2).uniq
    assert_equal combined.sort, parsed["aliases"].sort
  end

  test "chunks keep aliases from their own page" do
    parsed = JSON.parse(ChunkMergerService.merge(page_results))

    assert_equal ALIASES1, parsed["chunks"][0]["aliases"]
    assert_equal ALIASES1, parsed["chunks"][1]["aliases"]
    assert_equal ALIASES2, parsed["chunks"][2]["aliases"]
  end

  test "explicit chunk aliases override page aliases" do
    page = JSON.parse(page1_json)
    page["chunks"][0]["aliases"] = [ "P41", "hydraulic label" ]
    results = [ { page_number: 1, text: page.to_json, usage: nil, model: "claude-sonnet-4-6" } ]

    parsed = JSON.parse(ChunkMergerService.merge(results))

    assert_equal [ "P41", "hydraulic label" ], parsed["chunks"][0]["aliases"]
    assert_equal ALIASES1, parsed["chunks"][1]["aliases"]
  end

  test "preserves field records on their original chunk" do
    page = JSON.parse(page1_json)
    record = {
      "source_section_or_page" => "Section 2.4",
      "record_type" => "FUNCTIONAL_TEST",
      "action" => "Press the horn button.",
      "expected_result" => "The horn sounds."
    }
    page["chunks"][1]["field_records"] = [ record ]
    results = [ { page_number: 1, text: page.to_json, usage: nil, model: "claude-sonnet-4-6" } ]

    parsed = JSON.parse(ChunkMergerService.merge(results))

    assert_nil parsed["chunks"][0]["field_records"]
    assert_equal [ record ], parsed["chunks"][1]["field_records"]
  end

  test "caps document aliases at 15 and chunk aliases at 8" do
    aliases = 20.times.map { |index| "alias #{index}" }
    page = {
      "document_name" => DOC_NAME,
      "aliases" => aliases,
      "chunks" => [ { "text" => "content", "page" => 1, "aliases" => aliases } ]
    }

    parsed = JSON.parse(
      ChunkMergerService.merge([
        { page_number: 1, text: page.to_json, usage: nil, model: "claude-sonnet-4-6" }
      ])
    )

    assert_equal 15, parsed["aliases"].size
    assert_equal 8, parsed["chunks"].first["aliases"].size
  end

  test "chunks from all pages are concatenated in page order" do
    parsed = JSON.parse(ChunkMergerService.merge(page_results))
    assert_equal 3, parsed["chunks"].count
    assert_includes parsed["chunks"][0]["text"], "chunk 0"
    assert_includes parsed["chunks"][2]["text"], "page 3 chunk 0"
  end

  test "drops accidental document identification S0 chunks from non-anchor pages" do
    p1_json = {
      "document_name" => DOC_NAME,
      "aliases" => ALIASES1,
      "chunks" => [
        { "text" => "# S0 — DOCUMENT IDENTIFICATION\nAnchor identity.", "page" => 2 },
        { "text" => "# S4 — SAFETY SYSTEM\nAnchor safety.", "page" => 2 }
      ]
    }.to_json
    p2_json = {
      "document_name" => DOC_NAME,
      "aliases" => ALIASES2,
      "chunks" => [
        { "text" => "# S0 — DOCUMENT IDENTIFICATION\nStray content identity.", "page" => 3 },
        { "text" => "# S6 — ELECTRICAL\nReal content.", "page" => 3 }
      ]
    }.to_json

    parsed = JSON.parse(
      ChunkMergerService.merge([
        { page_number: 2, text: p1_json, usage: nil, model: "claude-sonnet-4-6" },
        { page_number: 3, text: p2_json, usage: nil, model: "claude-sonnet-4-6" }
      ])
    )

    texts = parsed["chunks"].pluck("text")
    assert_equal 3, texts.size
    assert_includes texts.join("\n"), "Anchor identity"
    assert_includes texts.join("\n"), "Real content"
    assert_not_includes texts.join("\n"), "Stray content identity"
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

  test "gracefully handles malformed JSON in one page — degraded marker added" do
    bad_results = [
      { page_number: 1, text: page1_json,    usage: nil, model: "claude-opus-4-7" },
      { page_number: 2, text: "not json {{", usage: nil, model: "claude-opus-4-7" }
    ]
    # Should not raise — bad page produces 1 degradation marker chunk
    parsed = JSON.parse(ChunkMergerService.merge(bad_results))
    assert_equal DOC_NAME, parsed["document_name"]
    # page 1 (2 chunks) + page 2 marker (1 chunk) = 3
    assert_equal 3, parsed["chunks"].count
    marker_chunk = parsed["chunks"].find { |c| c["page"] == 2 }
    assert_not_nil marker_chunk
    assert_includes marker_chunk["text"], "REQUIRES_FIELD_VERIFICATION"
    assert_includes marker_chunk["text"], "p2"
  end

  test "repairs B3 unescaped quotes in chunk text without degrading the page" do
    quoted_json = '{"document_name":"Orona ARCA II Manual","aliases":["ARCA II"],' \
      '"chunks":[{"text":"Consulte la sección "Etiquetas" y "Mantenimiento".","page":2,"field_records":[]}]}'
    report = ChunkMergerService.merge_with_report([
      { page_number: 2, text: quoted_json, usage: nil, model: "claude-sonnet-4-6" }
    ])

    parsed = JSON.parse(report[:json])

    assert_empty report[:degraded_pages]
    assert_equal 'Consulte la sección "Etiquetas" y "Mantenimiento".',
                 parsed.dig("chunks", 0, "text")
  end

  test "keeps unrecoverable JSON degraded" do
    broken_json = '{"document_name":"Manual","aliases":[],"chunks":[{"text":"unterminated","page":2}'
    report = ChunkMergerService.merge_with_report([
      { page_number: 1, text: page1_json, usage: nil, model: "claude-sonnet-4-6" },
      { page_number: 2, text: broken_json, usage: nil, model: "claude-sonnet-4-6" }
    ])
    parsed = JSON.parse(report[:json])

    assert_includes report[:degraded_pages], 2
    marker_chunk = parsed["chunks"].find { |chunk| chunk["page"] == 2 }
    assert_includes marker_chunk["text"], "REQUIRES_FIELD_VERIFICATION"
  end

  # ─── degradation marker ───────────────────────────────────────────────────────

  test "truncated page (stop_reason max_tokens) keeps parsed chunks and appends marker" do
    truncated_text = {
      "document_name" => DOC_NAME,
      "aliases"       => %w[HPM],
      "chunks"        => [ { "text" => "# S4 content", "page" => 2 } ]
    }.to_json

    results = [
      { page_number: 1, text: page1_json,      stop_reason: nil,          usage: nil, model: "claude-sonnet-4-6" },
      { page_number: 2, text: truncated_text,  stop_reason: "max_tokens", usage: nil, model: "claude-sonnet-4-6" }
    ]

    parsed = JSON.parse(ChunkMergerService.merge(results))
    # page 1 (2 chunks) + page 2 real chunk (1) + page 2 marker (1) = 4
    assert_equal 4, parsed["chunks"].count
    marker = parsed["chunks"].select { |c| c["page"] == 2 }.find { |c| c["text"].include?("REQUIRES_FIELD_VERIFICATION") }
    assert_not_nil marker, "expected degradation marker for page 2"
    real   = parsed["chunks"].select { |c| c["page"] == 2 }.find { |c| c["text"].include?("S4 content") }
    assert_not_nil real, "expected real chunk from page 2 to be preserved"
  end

  test "non-truncated pages produce empty degraded_pages" do
    report = ChunkMergerService.merge_with_report(page_results)
    assert_equal [], report[:degraded_pages]
    assert report[:json].is_a?(String)
  end

  test "merge_with_report reports degraded_pages for truncated and malformed pages" do
    truncated_text = {
      "document_name" => DOC_NAME,
      "aliases"       => [],
      "chunks"        => [ { "text" => "partial", "page" => 2 } ]
    }.to_json

    results = [
      { page_number: 1, text: page1_json,      stop_reason: nil,          usage: nil, model: "claude-sonnet-4-6" },
      { page_number: 2, text: truncated_text,  stop_reason: "max_tokens", usage: nil, model: "claude-sonnet-4-6" },
      { page_number: 3, text: "bad {{",        stop_reason: nil,          usage: nil, model: "claude-sonnet-4-6" }
    ]

    report = ChunkMergerService.merge_with_report(results)
    assert_includes report[:degraded_pages], 2
    assert_includes report[:degraded_pages], 3
    assert_not_includes report[:degraded_pages], 1
  end

  test "merge backward-compatible: still returns JSON string" do
    result = ChunkMergerService.merge(page_results)
    assert result.is_a?(String)
    parsed = JSON.parse(result)
    assert_equal DOC_NAME, parsed["document_name"]
  end

  # ─── summary + companion_offer from anchor ────────────────────────────────────

  test "merged JSON includes summary from anchor page (page 1)" do
    parsed = JSON.parse(ChunkMergerService.merge(page_results))
    assert_equal PAGE1_SUMMARY, parsed["summary"]
  end

  test "merged JSON includes companion_offer from anchor page (page 1)" do
    parsed = JSON.parse(ChunkMergerService.merge(page_results))
    assert_equal PAGE1_COMPANION_OFFER, parsed["companion_offer"]
  end

  test "summary comes from lowest-page anchor when page 1 is absent" do
    p2_json = {
      "document_name"   => "Manual Page 2",
      "aliases"         => %w[p2],
      "summary"         => "Summary from page 2.",
      "companion_offer" => "Offer from page 2.",
      "chunks"          => [ { "text" => "c2", "page" => 2 } ]
    }.to_json
    p5_json = {
      "document_name" => "Manual Page 5",
      "aliases"       => %w[p5],
      "summary"       => "Should not be used.",
      "chunks"        => [ { "text" => "c5", "page" => 5 } ]
    }.to_json

    results = [
      { page_number: 2, text: p2_json, usage: nil, model: "claude-opus-4-7" },
      { page_number: 5, text: p5_json, usage: nil, model: "claude-opus-4-7" }
    ]
    parsed = JSON.parse(ChunkMergerService.merge(results))
    assert_equal "Summary from page 2.", parsed["summary"]
    assert_equal "Offer from page 2.",   parsed["companion_offer"]
  end

  test "deterministic fallback summary when anchor page returns no summary" do
    no_summary_results = [
      { page_number: 1, text: page1_json(summary: nil, companion_offer: nil), usage: nil, model: "claude-sonnet-4-6" }
    ]
    parsed = JSON.parse(ChunkMergerService.merge(no_summary_results))
    assert parsed["summary"].present?, "expected fallback summary to be non-nil/non-empty"
    assert_includes parsed["summary"], DOC_NAME
  end

  test "deterministic fallback companion_offer when anchor page returns no companion_offer" do
    no_offer_results = [
      { page_number: 1, text: page1_json(summary: "Some summary.", companion_offer: nil), usage: nil, model: "claude-sonnet-4-6" }
    ]
    parsed = JSON.parse(ChunkMergerService.merge(no_offer_results))
    assert parsed["companion_offer"].present?, "expected fallback companion_offer to be non-nil/non-empty"
    assert_equal ChunkMergerService::FALLBACK_COMPANION_OFFER, parsed["companion_offer"]
  end

  test "fallback summary uses FALLBACK_COMPANION_OFFER constant when anchor fully absent" do
    degraded_results = [
      { page_number: 1, text: "not json {{", usage: nil, model: "claude-sonnet-4-6" }
    ]
    parsed = JSON.parse(ChunkMergerService.merge(degraded_results))
    assert parsed["summary"].present?
    assert_equal ChunkMergerService::FALLBACK_COMPANION_OFFER, parsed["companion_offer"]
  end

  test "all pages degraded (chosen_idx nil) does not raise and uses deterministic fallbacks" do
    all_degraded = [
      { page_number: 2, text: "broken {{",   usage: nil, model: "claude-sonnet-4-6" },
      { page_number: 5, text: "also bad ]]", usage: nil, model: "claude-sonnet-4-6" }
    ]

    report = nil
    assert_nothing_raised { report = ChunkMergerService.merge_with_report(all_degraded) }
    parsed = JSON.parse(report[:json])

    assert_equal "Unknown Document", parsed["document_name"]
    assert parsed["summary"].present?
    assert_equal ChunkMergerService::FALLBACK_COMPANION_OFFER, parsed["companion_offer"]
    assert_equal [ 2, 5 ], report[:degraded_pages]
    assert_equal 2, parsed["chunks"].count
  end
end
