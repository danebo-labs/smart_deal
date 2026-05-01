# frozen_string_literal: true

require "test_helper"

class KbDocumentEnrichmentJobTest < ActiveJob::TestCase
  setup do
    KbDocument.delete_all
  end

  test "enqueues on default queue" do
    assert_enqueued_with(job: KbDocumentEnrichmentJob, queue: "default") do
      KbDocumentEnrichmentJob.perform_later(doc_refs: [], retrieved_meta: [])
    end
  end

  test "delegates to KbDocumentEnrichmentService with the same args (renamed key)" do
    received = nil
    orig_new = KbDocumentEnrichmentService.method(:new)
    fake = Object.new
    fake.define_singleton_method(:call) do |doc_refs:, all_retrieved:|
      received = { doc_refs: doc_refs, all_retrieved: all_retrieved }
    end
    KbDocumentEnrichmentService.define_singleton_method(:new) { |*_a, **_kw| fake }

    refs = [ { "canonical_name" => "X", "source_uri" => "s3://b/x.pdf", "aliases" => [] } ]
    meta = [ { metadata: { "x-amz-bedrock-kb-source-uri" => "s3://b/x.pdf" }, location: { uri: "s3://b/x.pdf" } } ]

    KbDocumentEnrichmentJob.perform_now(doc_refs: refs, retrieved_meta: meta)

    assert_equal refs, received[:doc_refs]
    assert_equal meta, received[:all_retrieved]
  ensure
    KbDocumentEnrichmentService.define_singleton_method(:new) { |*a, **kw| orig_new.call(*a, **kw) }
  end

  test "is idempotent: running twice does not double-add aliases" do
    s3_uri = "s3://bucket/uploads/2026/manual.pdf"
    KbDocument.create!(s3_key: "uploads/2026/manual.pdf", display_name: "old name", aliases: [])

    refs = [ {
      "canonical_name" => "Manual de Operación",
      "source_uri"     => s3_uri,
      "aliases"        => [ "manop", "MO-3000" ]
    } ]

    KbDocumentEnrichmentJob.perform_now(doc_refs: refs, retrieved_meta: [])
    KbDocumentEnrichmentJob.perform_now(doc_refs: refs, retrieved_meta: [])

    kb = KbDocument.find_by(s3_key: "uploads/2026/manual.pdf")
    assert_equal "Manual de Operación", kb.display_name
    assert_equal kb.aliases, kb.aliases.uniq, "aliases must be unique after re-run"
    assert_includes kb.aliases, "manop"
    assert_includes kb.aliases, "MO-3000"
  end
end
