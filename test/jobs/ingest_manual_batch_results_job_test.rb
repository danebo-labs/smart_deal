# frozen_string_literal: true

require "test_helper"
require "ostruct"

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

  test "dormant chain retries invalid-JSON pages via shared service with web_batch_retry prefix (B.1)" do
    sha = Digest::SHA256.hexdigest("manual-bytes")
    invalid_json = '{"document_name":"Manual","chunks":[{"text":"unterminated","page":6}'
    valid_json = JSON.generate(
      "document_name" => "Orona ARCA II Manual",
      "aliases"       => [ "ARCA II" ],
      "chunks"        => [ { "text" => "S0 content", "page" => 6, "field_records" => [] } ]
    )

    ctx = {
      batch_id: "batch_b1", filename: "manual.pdf", sha256: sha,
      s3_key: "uploads/manual.pdf", page_customs: { 6 => "#{sha[0, 16]}_p6" },
      kept_pages: [ 6 ], conv_session_id: nil, kb_doc_id: nil,
      account_id: accounts(:legacy).id, document_uid: sha[0, 36]
    }

    message = OpenStruct.new(
      model:       "claude-sonnet-4-6",
      content:     [ OpenStruct.new(type: "text", text: invalid_json) ],
      usage:       FakeUsage.new(input_tokens: 2_000, output_tokens: 1_500),
      stop_reason: "end_turn"
    )
    fake_batch_client = Object.new
    fake_batch_client.define_singleton_method(:results_each) do |batch_id:, &block|
      block.call(OpenStruct.new(custom_id: "#{sha[0, 16]}_p6",
                                result: OpenStruct.new(type: "succeeded", message: message)))
    end

    captured = nil
    fake_retry = Object.new
    fake_retry.define_singleton_method(:retry_failed_pages!) do |**kwargs|
      captured = kwargs
      kwargs[:page_results].each { |pr| pr[:text] = valid_json; pr[:stop_reason] = nil }
      kwargs[:page_results]
    end

    original_retry_new  = BatchPageRetryService.method(:new)
    original_upload     = S3DocumentsService.instance_method(:upload_text)
    original_sync       = BulkKbSyncService.instance_method(:sync!)
    BatchPageRetryService.define_singleton_method(:new) { fake_retry }
    S3DocumentsService.define_method(:upload_text) { |_key, _body| nil }
    BulkKbSyncService.define_method(:sync!) { |**| nil } # stop after parse — no Bedrock sync path

    IngestManualBatchResultsJob.new.send(:ingest_results, ctx, fake_batch_client)

    assert captured, "shared retry service must run before the merger"
    assert_equal "web_batch_retry",    captured[:tracking_prefix]
    assert_equal "uploads/manual.pdf", captured[:s3_key]
    assert_equal sha,                  captured[:sha256]
    assert_equal 6,                    captured[:page_results].first[:page_number]
  ensure
    BatchPageRetryService.define_singleton_method(:new, original_retry_new) if defined?(original_retry_new)
    S3DocumentsService.define_method(:upload_text, original_upload) if defined?(original_upload)
    BulkKbSyncService.define_method(:sync!, original_sync) if defined?(original_sync)
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

  test "polling uses durable WebManualBatch context and re-enqueues while in_progress" do
    batch = WebManualBatch.create!(
      s3_key: "uploads/manual.pdf",
      filename: "manual.pdf",
      sha256: Digest::SHA256.hexdigest("manual"),
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      claude_batch_id: "msgbatch_poll",
      status: "submitted",
      page_customs: { 1 => "custom_p1" },
      kept_pages: [ 1 ]
    )

    fake_client = Object.new
    fake_client.define_singleton_method(:retrieve) { |batch_id:| OpenStruct.new(processing_status: "in_progress") }
    orig_client_new = ClaudeBatchClient.method(:new)
    ClaudeBatchClient.define_singleton_method(:new) { fake_client }

    assert_enqueued_with(job: IngestManualBatchResultsJob) do
      IngestManualBatchResultsJob.perform_now(web_manual_batch_id: batch.id)
    end

    assert_equal "in_progress", batch.reload.status
  ensure
    ClaudeBatchClient.define_singleton_method(:new, orig_client_new) if defined?(orig_client_new)
  end

  test "polls all batch ids and consumes every result stream only after all have ended" do
    batch = WebManualBatch.create!(
      s3_key: "uploads/multi.pdf",
      filename: "multi.pdf",
      sha256: Digest::SHA256.hexdigest("multi"),
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      claude_batch_id: "batch_1",
      claude_batch_ids: %w[batch_1 batch_2],
      status: "submitted",
      page_customs: { 1 => "custom_p1", 2 => "custom_p2" },
      kept_pages: [ 1, 2 ]
    )

    retrieved = []
    streamed = []
    fake_client = Object.new
    fake_client.define_singleton_method(:retrieve) do |batch_id:|
      retrieved << batch_id
      OpenStruct.new(processing_status: "ended")
    end
    fake_client.define_singleton_method(:results_each) do |batch_id:, &block|
      streamed << batch_id
    end
    orig_client_new = ClaudeBatchClient.method(:new)
    ClaudeBatchClient.define_singleton_method(:new) { fake_client }

    assert_no_enqueued_jobs only: IngestManualBatchResultsJob do
      IngestManualBatchResultsJob.perform_now(web_manual_batch_id: batch.id)
    end

    assert_equal %w[batch_1 batch_2], retrieved
    assert_equal %w[batch_1 batch_2], streamed
    assert_equal "failed", batch.reload.status
    assert_includes batch.error_message, "No succeeded batch results"
  ensure
    ClaudeBatchClient.define_singleton_method(:new, orig_client_new) if defined?(orig_client_new)
  end
end
