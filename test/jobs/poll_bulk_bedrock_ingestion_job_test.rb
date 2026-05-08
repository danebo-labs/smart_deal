# frozen_string_literal: true

require "test_helper"

class PollBulkBedrockIngestionJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Fake IngestionStatusService
  # ---------------------------------------------------------------------------

  class FakeIngestionService
    attr_reader :cleared

    def initialize(status)
      @status  = status
      @cleared = false
    end

    def job_status(_job_id) = @status
    def clear_when_complete(_job_id) = @cleared = true
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def make_bulk_upload(bedrock_ingestion_job_id: "bedrock-job-123", status: "processing")
    BulkUpload.create!(
      sha256:                    SecureRandom.hex(16),
      original_filename:         "batch.zip",
      status:                    status,
      asset_count:               0,
      bedrock_ingestion_job_id:  bedrock_ingestion_job_id
    )
  end

  def make_asset(bulk_upload, status: "syncing", s3_key: "bulk_uploads/2026-05-07/test.jpg",
                 canonical_name: "Manual técnico A", aliases: [ "manual A", "técnico A" ])
    BulkUploadAsset.create!(
      bulk_upload:    bulk_upload,
      custom_id:      SecureRandom.hex(16),
      sha256:         SecureRandom.hex(32),
      filename:       "test.jpg",
      status:         status,
      s3_key:         s3_key,
      canonical_name: canonical_name,
      aliases:        aliases
    )
  end

  def stub_ingestion_service(status)
    fake         = FakeIngestionService.new(status)
    original_new = IngestionStatusService.method(:new)
    IngestionStatusService.define_singleton_method(:new) { |**_kw| fake }
    yield fake
  ensure
    IngestionStatusService.define_singleton_method(:new) { |*a, **kw| original_new.call(*a, **kw) }
  end

  # ---------------------------------------------------------------------------
  # Step 14 — COMPLETE path
  # ---------------------------------------------------------------------------

  test "COMPLETE: transitions syncing assets to complete and creates KbDocuments" do
    upload = make_bulk_upload
    asset  = make_asset(upload)

    stub_ingestion_service("COMPLETE") do
      PollBulkBedrockIngestionJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601)
    end

    asset.reload
    assert_equal "complete", asset.status

    kb_doc = KbDocument.find_by(s3_key: asset.s3_key)
    assert_not_nil kb_doc
    assert_equal "Manual técnico A", kb_doc.display_name
    assert_includes kb_doc.aliases, "manual A"
    assert_equal kb_doc.id, asset.kb_document_id
  end

  test "COMPLETE: derives BulkUpload status to complete when all assets done" do
    upload = make_bulk_upload
    make_asset(upload)

    stub_ingestion_service("COMPLETE") do
      PollBulkBedrockIngestionJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601)
    end

    assert_equal "complete", upload.reload.status
  end

  test "COMPLETE: does not add canonical_name as its own alias" do
    upload = make_bulk_upload
    asset  = make_asset(upload, aliases: [ "Manual técnico A", "otro alias" ])

    stub_ingestion_service("COMPLETE") do
      PollBulkBedrockIngestionJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601)
    end

    kb_doc = KbDocument.find_by(s3_key: asset.s3_key)
    assert_not_includes kb_doc.aliases.map(&:downcase), "manual técnico a"
    assert_includes kb_doc.aliases, "otro alias"
  end

  test "COMPLETE: skips upsert_kb_document when asset s3_key is blank" do
    upload = make_bulk_upload
    asset  = make_asset(upload, s3_key: "")

    stub_ingestion_service("COMPLETE") do
      PollBulkBedrockIngestionJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601)
    end

    assert_equal "complete", asset.reload.status
    assert_nil asset.kb_document_id
  end

  # ---------------------------------------------------------------------------
  # FAILED / STOPPED path
  # ---------------------------------------------------------------------------

  test "FAILED: transitions syncing assets to failed" do
    upload = make_bulk_upload
    asset  = make_asset(upload)

    stub_ingestion_service("FAILED") do
      PollBulkBedrockIngestionJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601)
    end

    asset.reload
    assert_equal "failed", asset.status
    assert_match(/failed/, asset.error_message)
  end

  test "FAILED: derives BulkUpload status to failed" do
    upload = make_bulk_upload
    make_asset(upload)

    stub_ingestion_service("FAILED") do
      PollBulkBedrockIngestionJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601)
    end

    assert_equal "failed", upload.reload.status
  end

  # ---------------------------------------------------------------------------
  # Re-enqueue path
  # ---------------------------------------------------------------------------

  test "re-enqueues itself when status is IN_PROGRESS" do
    upload = make_bulk_upload

    stub_ingestion_service("IN_PROGRESS") do
      assert_enqueued_with(job: PollBulkBedrockIngestionJob) do
        PollBulkBedrockIngestionJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601, wait_seconds: 5)
      end
    end
  end

  test "next wait_seconds doubles up to MAX_WAIT cap" do
    upload = make_bulk_upload

    stub_ingestion_service("IN_PROGRESS") do
      PollBulkBedrockIngestionJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601, wait_seconds: 200)

      enqueued = enqueued_jobs.last
      assert_not_nil enqueued
      kwargs = enqueued[:args].last
      assert_equal PollBulkBedrockIngestionJob::MAX_WAIT, kwargs["wait_seconds"]
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout
  # ---------------------------------------------------------------------------

  test "marks assets failed after hard timeout" do
    upload = make_bulk_upload
    asset  = make_asset(upload)

    stub_ingestion_service("IN_PROGRESS") do
      PollBulkBedrockIngestionJob.perform_now(
        upload.id,
        started_at_iso: 20.minutes.ago.iso8601,
        wait_seconds:   5
      )
    end

    assert_equal "failed", asset.reload.status
    assert_match(/timed out/, asset.error_message)
    assert_no_enqueued_jobs only: PollBulkBedrockIngestionJob
  end

  # ---------------------------------------------------------------------------
  # Guard clauses
  # ---------------------------------------------------------------------------

  test "returns early if BulkUpload already failed" do
    upload = make_bulk_upload(status: "failed")

    stub_ingestion_service("COMPLETE") do
      assert_no_enqueued_jobs do
        PollBulkBedrockIngestionJob.perform_now(upload.id)
      end
    end
  end

  test "returns early if bedrock_ingestion_job_id is blank" do
    upload = make_bulk_upload(bedrock_ingestion_job_id: nil)

    stub_ingestion_service("COMPLETE") do
      assert_no_enqueued_jobs do
        PollBulkBedrockIngestionJob.perform_now(upload.id)
      end
    end
  end
end
