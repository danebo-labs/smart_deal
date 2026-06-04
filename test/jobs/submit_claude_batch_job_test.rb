# frozen_string_literal: true

require "test_helper"
require "ostruct"

class SubmitClaudeBatchJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  def make_bulk(sha_suffix: SecureRandom.hex(8))
    BulkUpload.create!(
      sha256:            Digest::SHA256.hexdigest("submit_job_#{sha_suffix}"),
      original_filename: "test.zip",
      status:            "processing"
    )
  end

  teardown do
    BulkUploadAsset.joins(:bulk_upload)
                   .where(bulk_uploads: { original_filename: "test.zip" })
                   .destroy_all
    BulkUpload.where(original_filename: "test.zip").destroy_all
  end

  test "does not enqueue PollClaudeBatchJob when submit! returns nil (no uploaded_s3 assets)" do
    bulk = make_bulk

    orig_new = BatchIngestionService.method(:new)
    BatchIngestionService.define_singleton_method(:new) do
      svc = orig_new.call
      svc.define_singleton_method(:submit!) { |_bu| nil }
      svc
    end

    assert_no_enqueued_jobs(only: PollClaudeBatchJob) do
      SubmitClaudeBatchJob.perform_now(bulk.id)
    end
  ensure
    BatchIngestionService.define_singleton_method(:new, orig_new)
  end

  test "enqueues PollClaudeBatchJob when submit! returns a batch" do
    bulk = make_bulk
    fake_batch = OpenStruct.new(id: "msgbatch_test_123")

    orig_new = BatchIngestionService.method(:new)
    BatchIngestionService.define_singleton_method(:new) do
      svc = orig_new.call
      svc.define_singleton_method(:submit!) { |_bu| fake_batch }
      svc
    end

    assert_enqueued_with(job: PollClaudeBatchJob) do
      SubmitClaudeBatchJob.perform_now(bulk.id)
    end
  ensure
    BatchIngestionService.define_singleton_method(:new, orig_new)
  end
end
