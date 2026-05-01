# frozen_string_literal: true

require 'test_helper'

class KbDocumentEnrichmentServiceTest < ActiveSupport::TestCase
  setup do
    @svc = KbDocumentEnrichmentService.new
  end

  test "no-op when doc_refs is blank" do
    assert_nothing_raised { @svc.call(doc_refs: nil) }
    assert_nothing_raised { @svc.call(doc_refs: []) }
  end

  test "enriches existing kb_document display_name + aliases" do
    kb = KbDocument.create!(s3_key: "uploads/2026/enrich.pdf", display_name: "old name", aliases: [ "old alias" ])
    doc_refs = [ {
      "canonical_name" => "New Canonical",
      "source_uri"     => "s3://#{KbDocument::KB_BUCKET}/uploads/2026/enrich.pdf",
      "aliases"        => [ "fresh alias" ]
    } ]
    @svc.call(doc_refs: doc_refs)
    kb.reload
    assert_equal "New Canonical", kb.display_name
    assert_includes kb.aliases, "fresh alias"
    assert_includes kb.aliases, "old name"
  end

  test "caps aliases at 15 entries" do
    kb = KbDocument.create!(
      s3_key: "uploads/2026/many.pdf", display_name: "old",
      aliases: (1..10).map { |i| "existing alias #{i}" }
    )
    doc_refs = [ {
      "canonical_name" => "Dense Document",
      "source_uri"     => "s3://#{KbDocument::KB_BUCKET}/uploads/2026/many.pdf",
      "aliases"        => (1..10).map { |i| "new alias #{i}" }
    } ]
    @svc.call(doc_refs: doc_refs)
    kb.reload
    assert kb.aliases.size <= 15
  end

  test "is a no-op when source_uri is blank" do
    doc_refs = [ { "canonical_name" => "Unknown Doc", "source_uri" => "", "aliases" => [] } ]
    assert_nothing_raised { @svc.call(doc_refs: doc_refs) }
  end

  test "is a no-op when no matching KbDocument row exists" do
    doc_refs = [ { "canonical_name" => "Phantom", "source_uri" => "s3://bucket/nonexistent.pdf", "aliases" => [] } ]
    assert_nothing_raised { @svc.call(doc_refs: doc_refs) }
  end

  test "collapses multiple doc_refs with same source_uri into one enrichment" do
    kb = KbDocument.create!(s3_key: "uploads/2026/brake.jpeg", display_name: "old", aliases: [])
    s3_uri = "s3://#{KbDocument::KB_BUCKET}/uploads/2026/brake.jpeg"
    doc_refs = [
      { "canonical_name" => "Brake Assembly Unit", "source_uri" => s3_uri, "aliases" => [ "disc brake" ] },
      { "canonical_name" => "Brake Drum Assembly", "source_uri" => s3_uri, "aliases" => [ "drum brake" ] }
    ]
    @svc.call(doc_refs: doc_refs)
    kb.reload
    assert_equal "Brake Assembly Unit", kb.display_name
    assert_includes kb.aliases, "disc brake"
    assert_includes kb.aliases, "drum brake"
    assert_includes kb.aliases, "Brake Drum Assembly"
  end

  test "backfill: single doc_ref + single citation assigns URI via location" do
    kb = KbDocument.create!(s3_key: "uploads/2026/schema.pdf", display_name: "old", aliases: [])
    doc_refs = [ { "canonical_name" => "Schema Doc", "source_uri" => "", "aliases" => [] } ]
    citation = {
      content:  "schema content",
      location: { uri: "s3://#{KbDocument::KB_BUCKET}/uploads/2026/schema.pdf", type: "s3" },
      metadata: {}
    }
    @svc.call(doc_refs: doc_refs, all_retrieved: [ citation ])
    kb.reload
    assert_equal "Schema Doc", kb.display_name
  end

  test "skips doc_ref with blank canonical_name" do
    KbDocument.create!(s3_key: "uploads/2026/orphan.pdf", display_name: "Orphan", aliases: [])
    doc_refs = [ { "canonical_name" => "", "source_uri" => "s3://bucket/orphan.pdf", "aliases" => [] } ]
    count_before = KbDocument.count
    @svc.call(doc_refs: doc_refs)
    assert_equal count_before, KbDocument.count
  end
end
