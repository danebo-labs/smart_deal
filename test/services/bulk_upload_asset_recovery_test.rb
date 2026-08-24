# frozen_string_literal: true

require "test_helper"

class BulkUploadAssetRecoveryTest < ActiveJob::TestCase
  parallelize(workers: 1)

  def create_upload(batch_ids: %w[msgbatch_a msgbatch_b], status: "complete")
    BulkUpload.create!(
      sha256:            Digest::SHA256.hexdigest("recovery_#{SecureRandom.hex(8)}"),
      original_filename: "06_ingesta.zip",
      status:            status,
      claude_batch_ids:  batch_ids,
      user:              users(:one)
    )
  end

  def add_asset(upload, status:, filename: "file_#{SecureRandom.hex(4)}.pdf", error_message: nil)
    upload.bulk_upload_assets.create!(
      custom_id:     SecureRandom.hex(16),
      sha256:        Digest::SHA256.hexdigest("asset_#{SecureRandom.hex(8)}"),
      filename:      filename,
      content_type:  "application/pdf",
      status:        status,
      error_message: error_message
    )
  end

  # ---------------------------------------------------------------------------
  # Recovery
  # ---------------------------------------------------------------------------

  test "returns a failed asset to in_batch, clears its error and enqueues the ingest job" do
    upload = create_upload
    add_asset(upload, status: "complete")
    failed = add_asset(
      upload,
      status:        "failed",
      filename:      "CMC3 SCM Synergy.pdf",
      error_message: "Invalid k in chunk 47 field_record 11"
    )

    result = nil
    assert_enqueued_with(job: IngestBatchResultsJob, args: [ upload.id ]) do
      result = BulkUploadAssetRecovery.new(upload).call!
    end

    assert_equal [ "CMC3 SCM Synergy.pdf" ], result.recovered
    assert result.enqueued
    assert_equal "in_batch", failed.reload.status
    assert_nil failed.error_message
  end

  test "leaves assets that already succeeded untouched" do
    upload = create_upload
    done   = add_asset(upload, status: "complete")
    add_asset(upload, status: "failed")

    BulkUploadAssetRecovery.new(upload).call!

    assert_equal "complete", done.reload.status
  end

  test "recovers only the named assets" do
    upload = create_upload
    wanted = add_asset(upload, status: "failed", filename: "wanted.pdf")
    other  = add_asset(upload, status: "failed", filename: "other.pdf")

    result = BulkUploadAssetRecovery.new(upload, filenames: [ "wanted.pdf" ]).call!

    assert_equal [ "wanted.pdf" ], result.recovered
    assert_equal "in_batch", wanted.reload.status
    assert_equal "failed", other.reload.status
  end

  # ---------------------------------------------------------------------------
  # No-ops and idempotency
  # ---------------------------------------------------------------------------

  test "does nothing and enqueues nothing when no asset failed" do
    upload = create_upload
    add_asset(upload, status: "complete")

    result = nil
    assert_no_enqueued_jobs only: IngestBatchResultsJob do
      result = BulkUploadAssetRecovery.new(upload).call!
    end

    assert_empty result.recovered
    assert_not result.enqueued
  end

  # The second run must not re-enqueue: the asset is in flight by then, which is
  # exactly what the in-flight guard is for.
  test "a second run refuses while the recovered asset is still in flight" do
    upload = create_upload
    add_asset(upload, status: "failed")
    BulkUploadAssetRecovery.new(upload).call!

    assert_raises(BulkUploadAssetRecovery::Error) do
      BulkUploadAssetRecovery.new(upload).call!
    end
  end

  # ---------------------------------------------------------------------------
  # Guards
  # ---------------------------------------------------------------------------

  test "refuses when the upload has no batch ids to re-read" do
    upload = create_upload(batch_ids: [])
    add_asset(upload, status: "failed")

    error = assert_raises(BulkUploadAssetRecovery::Error) { BulkUploadAssetRecovery.new(upload).call! }
    assert_match(/no batch ids/, error.message)
  end

  test "refuses while other assets are still in flight" do
    upload = create_upload(status: "processing")
    add_asset(upload, status: "in_batch", filename: "still-running.pdf")
    add_asset(upload, status: "failed")

    error = assert_raises(BulkUploadAssetRecovery::Error) { BulkUploadAssetRecovery.new(upload).call! }
    assert_match(/still-running\.pdf/, error.message)
  end

  test "refuses an unknown filename instead of reporting nothing to recover" do
    upload = create_upload
    add_asset(upload, status: "failed", filename: "real.pdf")

    error = assert_raises(BulkUploadAssetRecovery::Error) do
      BulkUploadAssetRecovery.new(upload, filenames: [ "typo.pdf" ]).call!
    end
    assert_match(/no asset named: typo\.pdf/, error.message)
  end
end
