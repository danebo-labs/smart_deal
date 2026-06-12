# frozen_string_literal: true

require "test_helper"

class IngestManualBatchResultsJobTest < ActiveJob::TestCase
  FakeUsage = Struct.new(:input_tokens, :output_tokens,
                          :cache_read_input_tokens, :cache_creation_input_tokens,
                          keyword_init: true)

  FakeMessage = Struct.new(:model, :usage, keyword_init: true)

  test "track_page_usage enqueues TrackBedrockQueryJob with -batch model_id for LlmUsageChannel" do
    job = IngestManualBatchResultsJob.new
    msg = FakeMessage.new(
      model: "claude-sonnet-4-6-20250514",
      usage: FakeUsage.new(input_tokens: 3000, output_tokens: 500)
    )

    assert_enqueued_with(job: TrackBedrockQueryJob) do
      job.send(:track_page_usage, msg, "manual.pdf", 2, 5)
    end

    enqueued = enqueued_jobs.find { |j| j[:job] == TrackBedrockQueryJob }
    args = enqueued[:args].first

    assert_equal "claude-sonnet-4-6-20250514-batch", args["model_id"]
    assert_equal "web_batch: manual.pdf p2/5", args["user_query"]
    assert_equal "ingestion_parse", args["source"]
    assert_equal :anthropic_sonnet_batch,
                 LlmUsageChannel.for(model_id: args["model_id"], source: args["source"])
  end

  test "track_page_usage does not double-append -batch suffix" do
    job = IngestManualBatchResultsJob.new
    msg = FakeMessage.new(
      model: "claude-opus-4-7-batch",
      usage: FakeUsage.new(input_tokens: 100, output_tokens: 50)
    )

    job.send(:track_page_usage, msg, "scan.pdf", 1, 1)

    args = enqueued_jobs.find { |j| j[:job] == TrackBedrockQueryJob }[:args].first
    assert_equal "claude-opus-4-7-batch", args["model_id"]
  end

  test "track_page_usage records stop_reason, batch route, 8k cap and page correlation (I0/O3')" do
    job = IngestManualBatchResultsJob.new
    sha = Digest::SHA256.hexdigest("manual-bytes")
    msg = FakeMessage.new(
      model: "claude-sonnet-4-6",
      usage: FakeUsage.new(input_tokens: 2000, output_tokens: 8000)
    )

    job.send(:track_page_usage, msg, "manual.pdf", 3, 20, sha256: sha, stop_reason: "max_tokens")

    args = enqueued_jobs.find { |j| j[:job] == TrackBedrockQueryJob }[:args].first
    assert_equal "batch",                          args["route"]
    assert_equal 1,                                args["attempt"]
    assert_equal BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS, args["max_tokens"]
    assert_equal "max_tokens",                     args["stop_reason"]
    assert_equal "ingest:#{sha[0, 12]}:p3",        args["correlation_id"]
  end
end
