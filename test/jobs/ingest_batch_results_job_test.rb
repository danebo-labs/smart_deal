# frozen_string_literal: true

require "test_helper"

class IngestBatchResultsJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  test "track_asset_usage skips when message has no usage" do
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      job = IngestBatchResultsJob.new
      asset = Object.new
      asset.define_singleton_method(:update_columns) { |_| flunk("asset should not update without usage") }
      message = Struct.new(:content).new([])
      job.send(:track_asset_usage, asset, message)
    end
  end
end
