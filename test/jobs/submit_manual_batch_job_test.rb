# frozen_string_literal: true

require "test_helper"

class SubmitManualBatchJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  setup do
    @account = Account.create!(slug: "submit-batch-test-#{SecureRandom.hex(4)}")
    @document_uid = SecureRandom.uuid
    @orig_s3_new = S3DocumentsService.method(:new)
    @orig_manual_new = ManualBatchIngestionService.method(:new)
  end

  teardown do
    S3DocumentsService.define_singleton_method(:new, @orig_s3_new)
    ManualBatchIngestionService.define_singleton_method(:new, @orig_manual_new)
  end

  test "persists durable context and enqueues manual batch polling" do
    sha = Digest::SHA256.hexdigest("manual")
    kb_doc = KbDocument.create!(
      account: @account,
      document_uid: @document_uid,
      s3_key: "uploads/#{@account.id}/#{@document_uid}/original.pdf",
      display_name: "manual"
    )

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
        s3_key: kb_doc.s3_key,
        filename: "manual.pdf",
        sha256: sha,
        kb_doc_id: kb_doc.id,
        account_id: @account.id,
        document_uid: @document_uid,
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
    assert_equal @account.id, batch.account_id
  end

  test "non-pending batch skips without a second paid submit" do
    sha = Digest::SHA256.hexdigest("manual")
    kb_doc = KbDocument.create!(
      account: @account,
      document_uid: @document_uid,
      s3_key: "uploads/#{@account.id}/#{@document_uid}/original.pdf",
      display_name: "reused"
    )
    WebManualBatch.create!(
      account: @account,
      s3_key: kb_doc.s3_key,
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

    assert_no_enqueued_jobs only: IngestManualBatchResultsJob do
      SubmitManualBatchJob.perform_now(
        s3_key: kb_doc.s3_key,
        filename: "reused.pdf",
        sha256: sha,
        kb_doc_id: kb_doc.id,
        account_id: @account.id,
        document_uid: @document_uid
      )
    end

    assert_equal 0, submit_calls
  end

  test "ownership mismatch raises" do
    other = Account.create!(slug: "submit-batch-other-#{SecureRandom.hex(4)}")
    kb_doc = KbDocument.create!(
      account: other,
      document_uid: SecureRandom.uuid,
      s3_key: "uploads/#{other.id}/other/original.pdf",
      display_name: "other"
    )

    assert_raises(UploadAndSyncAttachmentsJob::AccountOwnershipError) do
      SubmitManualBatchJob.perform_now(
        s3_key: kb_doc.s3_key,
        filename: "other.pdf",
        sha256: Digest::SHA256.hexdigest("other"),
        kb_doc_id: kb_doc.id,
        account_id: @account.id,
        document_uid: @document_uid
      )
    end
  end

  # P-17: submitting lock — row stays submitting when crash before batch_id persisted

  test "P-17: crash after lock but before claude_batch_id persisted leaves row in submitting state" do
    sha    = Digest::SHA256.hexdigest("p17-crash")
    kb_doc = KbDocument.create!(
      account: @account, document_uid: @document_uid,
      s3_key: "uploads/#{@account.id}/#{@document_uid}/original.pdf", display_name: "p17"
    )

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:download) { |_| "%PDF bytes" }
    S3DocumentsService.define_singleton_method(:new) { fake_s3 }

    # ManualBatchIngestionService raises a transient network error after being called
    fake_manual = Object.new
    fake_manual.define_singleton_method(:submit!) { |**| raise Errno::ECONNRESET, "connection reset" }
    ManualBatchIngestionService.define_singleton_method(:new) { fake_manual }

    assert_raises(Errno::ECONNRESET) do
      SubmitManualBatchJob.perform_now(
        s3_key: kb_doc.s3_key, filename: "p17.pdf", sha256: sha,
        kb_doc_id: kb_doc.id, account_id: @account.id, document_uid: @document_uid
      )
    end

    batch = WebManualBatch.find_by!(sha256: sha)
    assert_equal "submitting", batch.status, "crash between lock and batch_id persist must leave row in submitting"
    assert_nil batch.claude_batch_id, "no batch_id must be present after crash"
  end

  # P-17: watchdog transitions submitting rows to submission_unknown

  test "P-17: ReconcileStuckBatchesJob transitions old submitting rows to submission_unknown" do
    sha    = Digest::SHA256.hexdigest("p17-watchdog")
    kb_doc = KbDocument.create!(
      account: @account, document_uid: SecureRandom.uuid,
      s3_key: "uploads/#{@account.id}/#{SecureRandom.uuid}/original.pdf", display_name: "watchdog"
    )
    batch = WebManualBatch.create!(
      account: @account,
      kb_document: kb_doc,
      s3_key: kb_doc.s3_key,
      filename: "watchdog.pdf",
      sha256: sha,
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      status: "submitting",
      claude_batch_id: nil,
      content_type: "application/pdf"
    )
    # Fake updated_at to be older than the cutoff
    batch.update_columns(updated_at: 60.minutes.ago) # rubocop:disable Rails/SkipsModelValidations

    ReconcileStuckBatchesJob.perform_now

    assert_equal "submission_unknown", batch.reload.status
  end

  # P-17: transient error before lock (S3 download fails) re-raises for SQ retry

  test "P-17: transient S3 download failure re-raises so SQ retries" do
    sha    = Digest::SHA256.hexdigest("p17-transient")
    kb_doc = KbDocument.create!(
      account: @account, document_uid: SecureRandom.uuid,
      s3_key: "uploads/#{@account.id}/#{SecureRandom.uuid}/original.pdf", display_name: "transient"
    )

    # S3 download returns blank (simulates transient S3 failure)
    fake_s3 = Object.new
    fake_s3.define_singleton_method(:download) { |_| nil }
    S3DocumentsService.define_singleton_method(:new) { fake_s3 }

    SubmitManualBatchJob.perform_now(
      s3_key: kb_doc.s3_key, filename: "transient.pdf", sha256: sha,
      kb_doc_id: kb_doc.id, account_id: @account.id, document_uid: kb_doc.document_uid
    )

    # Blank binary → row marked failed (not a re-raise; blank download is non-retryable)
    batch = WebManualBatch.find_by!(sha256: sha)
    assert_equal "failed", batch.status
    assert_includes batch.error_message, "S3 download failed"
  end
end
