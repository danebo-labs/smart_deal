# frozen_string_literal: true

require "test_helper"
require "ostruct"

class PollClaudeBatchJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  BATCH_ID = "msgbatch_poll_test"

  # ---------------------------------------------------------------------------
  # Fake Anthropic client
  # ---------------------------------------------------------------------------

  class FakeBatchClient
    def initialize(processing_status:)
      @processing_status = processing_status
    end

    def retrieve(batch_id:) # rubocop:disable Lint/UnusedMethodArgument
      OpenStruct.new(processing_status: @processing_status)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def make_bulk_upload(status: "processing", claude_batch_id: BATCH_ID)
    BulkUpload.create!(
      sha256:            SecureRandom.hex(16),
      original_filename: "test.zip",
      status:            status,
      claude_batch_id:   claude_batch_id,
      asset_count:       0
    )
  end

  def stub_batch_client(processing_status:)
    fake = FakeBatchClient.new(processing_status: processing_status)
    original_new = ClaudeBatchClient.method(:new)
    ClaudeBatchClient.define_singleton_method(:new) { |**_kw| fake }
    yield
  ensure
    ClaudeBatchClient.define_singleton_method(:new) { |*a, **kw| original_new.call(*a, **kw) }
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  test "enqueues IngestBatchResultsJob when batch is ended" do
    upload = make_bulk_upload
    stub_batch_client(processing_status: "ended") do
      assert_enqueued_with(job: IngestBatchResultsJob, args: [ upload.id ]) do
        PollClaudeBatchJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601)
      end
    end
  end

  test "re-enqueues itself when batch is still in_progress" do
    upload = make_bulk_upload
    stub_batch_client(processing_status: "in_progress") do
      assert_enqueued_with(job: PollClaudeBatchJob) do
        PollClaudeBatchJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601, wait_seconds: 30)
      end
    end
  end

  test "next wait_seconds doubles up to MAX_WAIT cap" do
    upload = make_bulk_upload
    stub_batch_client(processing_status: "in_progress") do
      PollClaudeBatchJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601, wait_seconds: 200)

      enqueued = enqueued_jobs.last
      assert_not_nil enqueued
      kwargs = enqueued[:args].last
      assert_equal PollClaudeBatchJob::MAX_WAIT, kwargs["wait_seconds"]
    end
  end

  test "marks BulkUpload and in_batch assets failed after 24h timeout" do
    upload = make_bulk_upload
    asset  = BulkUploadAsset.create!(
      bulk_upload: upload,
      custom_id:   SecureRandom.hex(16),
      sha256:      SecureRandom.hex(32),
      filename:    "photo.jpg",
      status:      "in_batch"
    )

    stub_batch_client(processing_status: "in_progress") do
      PollClaudeBatchJob.perform_now(
        upload.id,
        started_at_iso: 25.hours.ago.iso8601,
        wait_seconds:   30
      )
    end

    assert_equal "failed", upload.reload.status
    assert_equal "failed", asset.reload.status
    assert_match(/timed out/, upload.error_message)
    assert_no_enqueued_jobs only: IngestBatchResultsJob
  end

  test "skips early if bulk_upload already failed" do
    upload = make_bulk_upload(status: "failed")
    stub_batch_client(processing_status: "in_progress") do
      assert_no_enqueued_jobs do
        PollClaudeBatchJob.perform_now(upload.id)
      end
    end
  end

  test "skips when claude_batch_id is blank" do
    upload = make_bulk_upload(claude_batch_id: nil)
    stub_batch_client(processing_status: "in_progress") do
      assert_no_enqueued_jobs do
        PollClaudeBatchJob.perform_now(upload.id)
      end
    end
  end
end
