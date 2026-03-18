# frozen_string_literal: true

require "test_helper"

class BedrockIngestionJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper

  def with_mock_ingestion_service(job_status_results)
    call_index = 0
    mock_service = Object.new
    mock_service.define_singleton_method(:job_status) do |_job_id|
      result = job_status_results[call_index] || job_status_results.last
      call_index += 1
      result
    end
    mock_service.define_singleton_method(:clear_when_complete) { |_job_id| true }
    mock_service.define_singleton_method(:failure_reasons) { |_job_id| [] }

    original_new = IngestionStatusService.method(:new)
    IngestionStatusService.define_singleton_method(:new) { |*_args| mock_service }
    yield
  ensure
    IngestionStatusService.define_singleton_method(:new) { |*args, **kwargs| original_new.call(*args, **kwargs) }
  end

  test "enqueues correctly" do
    assert_enqueued_with(job: BedrockIngestionJob, args: [ "job-123", [ "doc.txt" ] ]) do
      BedrockIngestionJob.perform_later("job-123", [ "doc.txt" ])
    end
  end

  test "broadcasts indexed when job completes successfully" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
      end
      assert_equal 1, messages.size
      assert_equal "indexed", messages.first["status"]
      assert_equal [ "doc.txt" ], messages.first["filenames"]
      assert_includes messages.first["message"], "doc.txt"
    end
  end

  test "broadcasts failed when job status is FAILED" do
    with_mock_ingestion_service(%w[FAILED]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
      end
      assert_equal 1, messages.size
      assert_equal "failed", messages.first["status"]
    end
  end

  test "skips perform when ingestion_job_id is blank" do
    with_mock_ingestion_service(%w[COMPLETE]) do
      assert_no_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now(nil, [ "doc.txt" ])
      end
    end
  end

  test "polls until COMPLETE" do
    with_mock_ingestion_service(%w[IN_PROGRESS IN_PROGRESS COMPLETE]) do
      messages = capture_broadcasts("kb_sync") do
        BedrockIngestionJob.perform_now("job-123", [ "doc.txt" ])
      end
      assert_equal 1, messages.size
      assert_equal "indexed", messages.first["status"]
    end
  end
end
