# frozen_string_literal: true

require 'test_helper'

class KbDocumentEnrichmentServiceTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:legacy)
    @other_account = accounts(:climb)
    @svc = KbDocumentEnrichmentService.new(account_id: @account.id)
  end

  test "no-op when doc_refs is blank" do
    assert_nothing_raised { @svc.call(doc_refs: nil) }
    assert_nothing_raised { @svc.call(doc_refs: []) }
  end

  test "keeps existing display_name and merges canonical into aliases" do
    kb = create_doc("uploads/2026/enrich.pdf", "old name", aliases: [ "old alias" ])
    doc_refs = [ {
      "canonical_name" => "New Canonical",
      "source_uri"     => "s3://#{KbDocument::KB_BUCKET}/uploads/2026/enrich.pdf",
      "aliases"        => [ "fresh alias" ]
    } ]
    @svc.call(doc_refs: doc_refs)
    kb.reload
    assert_equal "old name", kb.display_name
    assert_includes kb.aliases, "New Canonical"
    assert_includes kb.aliases, "fresh alias"
    assert_includes kb.aliases, "old alias"
  end

  test "sets display_name from canonical when the row has none yet (orphan onboarding)" do
    kb = create_doc("uploads/2026/orphan-onboard.pdf", "")
    doc_refs = [ {
      "canonical_name" => "First Canonical Name",
      "source_uri"     => "s3://#{KbDocument::KB_BUCKET}/uploads/2026/orphan-onboard.pdf",
      "aliases"        => [ "fresh alias" ]
    } ]
    @svc.call(doc_refs: doc_refs)
    kb.reload
    assert_equal "First Canonical Name", kb.display_name
    assert_includes kb.aliases, "fresh alias"
    assert_not_includes kb.aliases, "First Canonical Name"
  end

  test "does not rename SEGURIDADES 1.1-1 to a Haiku-discovered canonical name" do
    kb = create_doc("uploads/2026/seguridades.pdf", "SEGURIDADES 1.1-1", aliases: [ "SEGURIDADES" ])
    doc_refs = [ {
      "canonical_name" => "ALJO Control Level 1B Altius",
      "source_uri"     => "s3://#{KbDocument::KB_BUCKET}/uploads/2026/seguridades.pdf",
      "aliases"        => []
    } ]
    @svc.call(doc_refs: doc_refs)
    kb.reload
    assert_equal "SEGURIDADES 1.1-1", kb.display_name
    assert_includes kb.aliases, "ALJO Control Level 1B Altius"
  end

  test "caps aliases at 15 entries" do
    kb = KbDocument.create!(
      s3_key: "uploads/2026/many.pdf", display_name: "old",
      aliases: (1..10).map { |i| "existing alias #{i}" },
      account: @account
    )
    doc_refs = [ {
      "canonical_name" => "Dense Document",
      "source_uri"     => "s3://#{KbDocument::KB_BUCKET}/uploads/2026/many.pdf",
      "aliases"        => (1..10).map { |i| "new alias #{i}" }
    } ]
    @svc.call(doc_refs: doc_refs)
    kb.reload
    assert_equal "old", kb.display_name
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
    kb = create_doc("uploads/2026/brake.jpeg", "old")
    s3_uri = "s3://#{KbDocument::KB_BUCKET}/uploads/2026/brake.jpeg"
    doc_refs = [
      { "canonical_name" => "Brake Assembly Unit", "source_uri" => s3_uri, "aliases" => [ "disc brake" ] },
      { "canonical_name" => "Brake Drum Assembly", "source_uri" => s3_uri, "aliases" => [ "drum brake" ] }
    ]
    @svc.call(doc_refs: doc_refs)
    kb.reload
    assert_equal "old", kb.display_name
    assert_includes kb.aliases, "disc brake"
    assert_includes kb.aliases, "drum brake"
    assert_includes kb.aliases, "Brake Assembly Unit"
    assert_includes kb.aliases, "Brake Drum Assembly"
  end

  test "backfill: single doc_ref + single citation assigns URI via location" do
    kb = create_doc("uploads/2026/schema.pdf", "old")
    doc_refs = [ { "canonical_name" => "Schema Doc", "source_uri" => "", "aliases" => [] } ]
    citation = {
      content:  "schema content",
      location: { uri: "s3://#{KbDocument::KB_BUCKET}/uploads/2026/schema.pdf", type: "s3" },
      metadata: {}
    }
    @svc.call(doc_refs: doc_refs, all_retrieved: [ citation ])
    kb.reload
    assert_equal "old", kb.display_name
    assert_includes kb.aliases, "Schema Doc"
  end

  test "skips doc_ref with blank canonical_name" do
    create_doc("uploads/2026/orphan.pdf", "Orphan")
    doc_refs = [ { "canonical_name" => "", "source_uri" => "s3://bucket/orphan.pdf", "aliases" => [] } ]
    count_before = KbDocument.count
    @svc.call(doc_refs: doc_refs)
    assert_equal count_before, KbDocument.count
  end

  test "does not enrich matching s3_key from another account" do
    other_doc = KbDocument.create!(
      s3_key: "uploads/2026/other-enrich.pdf",
      display_name: "old other",
      aliases: [],
      account: @other_account
    )

    @svc.call(doc_refs: [ {
      "canonical_name" => "Wrong Account",
      "source_uri" => "s3://#{KbDocument::KB_BUCKET}/uploads/2026/other-enrich.pdf",
      "aliases" => [ "wrong" ]
    } ])

    other_doc.reload
    assert_equal "old other", other_doc.display_name
    assert_empty other_doc.aliases
  end

  private

  def create_doc(s3_key, display_name, aliases: [])
    KbDocument.create!(s3_key: s3_key, display_name: display_name, aliases: aliases, account: @account)
  end
end
