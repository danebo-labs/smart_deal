# frozen_string_literal: true

require "test_helper"

class SubmitManualBatchJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  setup do
    @orig_s3_new = S3DocumentsService.method(:new)
    @orig_manual_new = ManualBatchIngestionService.method(:new)
  end

  teardown do
    S3DocumentsService.define_singleton_method(:new, @orig_s3_new)
    ManualBatchIngestionService.define_singleton_method(:new, @orig_manual_new)
  end

  test "persists durable context and enqueues manual batch polling" do
    sha = Digest::SHA256.hexdigest("manual")
    kb_doc = KbDocument.create!(s3_key: "uploads/manual.pdf", display_name: "manual")

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:download) { |_key| "%PDF bytes" }
    S3DocumentsService.define_singleton_method(:new) { fake_s3 }

    fake_manual = Object.new
    fake_manual.define_singleton_method(:submit!) do |**|
      {
        batch_id: "msgbatch_web_123",
        page_customs: { 1 => "#{sha[0, 16]}_p1" },
        kept_pages: [ 1 ],
        total_pages: 3
      }
    end
    ManualBatchIngestionService.define_singleton_method(:new) { fake_manual }

    assert_enqueued_with(job: IngestManualBatchResultsJob) do
      SubmitManualBatchJob.perform_now(
        s3_key: "uploads/manual.pdf",
        filename: "manual.pdf",
        sha256: sha,
        kb_doc_id: kb_doc.id,
        locale: "es",
        conv_session_id: nil
      )
    end

    batch = WebManualBatch.find_by!(sha256: sha)
    assert_equal "submitted", batch.status
    assert_equal "msgbatch_web_123", batch.claude_batch_id
    assert_equal({ "1" => "#{sha[0, 16]}_p1" }, batch.page_customs)
    assert_equal [ 1 ], batch.kept_pages
    assert_equal kb_doc.id, batch.kb_document_id
  end

  test "resubmission reuses submitted batch without a second paid submit" do
    sha = Digest::SHA256.hexdigest("manual")
    kb_doc = KbDocument.create!(s3_key: "uploads/reused.pdf", display_name: "reused")
    WebManualBatch.create!(
      s3_key: "uploads/reused.pdf",
      filename: "reused.pdf",
      sha256: sha,
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      claude_batch_id: "msgbatch_existing",
      status: "submitted",
      kb_document_id: kb_doc.id
    )

    submit_calls = 0
    fake_manual = Object.new
    fake_manual.define_singleton_method(:submit!) { |**| submit_calls += 1 }
    ManualBatchIngestionService.define_singleton_method(:new) { fake_manual }

    assert_enqueued_with(job: IngestManualBatchResultsJob) do
      SubmitManualBatchJob.perform_now(
        s3_key: "uploads/reused.pdf",
        filename: "reused.pdf",
        sha256: sha,
        kb_doc_id: kb_doc.id
      )
    end

    assert_equal 0, submit_calls
  end
end
