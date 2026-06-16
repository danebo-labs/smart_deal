# frozen_string_literal: true

require "test_helper"

class ProcessManualUrgentTriageJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  setup do
    @orig_s3_new = S3DocumentsService.method(:new)
    @orig_service_new = ManualUrgentTriageService.method(:new)
  end

  teardown do
    S3DocumentsService.define_singleton_method(:new, @orig_s3_new)
    ManualUrgentTriageService.define_singleton_method(:new, @orig_service_new)
  end

  test "downloads PDF and records urgent triage syncing state" do
    kb_doc = KbDocument.create!(s3_key: "uploads/manual.pdf", display_name: "manual")
    sha = Digest::SHA256.hexdigest("manual")

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:download) { |_key| "%PDF bytes" }
    S3DocumentsService.define_singleton_method(:new) { fake_s3 }

    fake_service = Object.new
    fake_service.define_singleton_method(:call) do |**kwargs|
      {
        "selected_pages" => [ 2, 5 ],
        "chunks_s3_prefix" => "bulk_chunks/#{kwargs[:sha256]}/field_records_v3",
        "processing_scope" => "urgent_pages"
      }
    end
    ManualUrgentTriageService.define_singleton_method(:new) { fake_service }

    ProcessManualUrgentTriageJob.perform_now(
      s3_key: "uploads/manual.pdf",
      filename: "manual.pdf",
      sha256: sha,
      kb_doc_id: kb_doc.id,
      query: "rescate emergencia",
      locale: "es",
      conv_session_id: nil
    )

    batch = WebManualBatch.find_by!(sha256: sha)
    assert_equal "syncing", batch.urgent_status
    assert_equal [ 2, 5 ], batch.urgent_pages
    assert_match "bulk_chunks/", batch.urgent_chunks_s3_prefix
  end

  test "skips paid triage when urgent pages are already syncing" do
    kb_doc = KbDocument.create!(s3_key: "uploads/manual.pdf", display_name: "manual")
    sha = Digest::SHA256.hexdigest("manual")
    WebManualBatch.create!(
      s3_key: "uploads/manual.pdf",
      filename: "manual.pdf",
      sha256: sha,
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      status: "submitted",
      urgent_status: "syncing",
      urgent_pages: [ 2 ],
      kb_document_id: kb_doc.id
    )

    service_called = false
    fake_service = Object.new
    fake_service.define_singleton_method(:call) { |**| service_called = true }
    ManualUrgentTriageService.define_singleton_method(:new) { fake_service }

    ProcessManualUrgentTriageJob.perform_now(
      s3_key: "uploads/manual.pdf",
      filename: "manual.pdf",
      sha256: sha,
      kb_doc_id: kb_doc.id,
      query: "rescate emergencia"
    )

    assert_not service_called
  end
end
