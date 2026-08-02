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

  # ---------------------------------------------------------------------------
  # Fase 5 / I-37: the edges derived at submission time survive the Batch API
  # round trip on the web_manual_batches row and reach the chunk body. This is
  # the ONLY route the pilot web upload uses, so without this the contract v8
  # record could never appear in production for either tier.
  # ---------------------------------------------------------------------------

  test "persisted page_topology_edges reach the chunk body after the batch round trip" do
    sha = Digest::SHA256.hexdigest("topology-manual")
    page_json = JSON.generate(
      "document_name" => "CTA SR8P Bornas Carril",
      "aliases"       => [ "CTA SR8P" ],
      "chunks"        => [ { "text" => "S4 contenido de la página", "page" => 17, "field_records" => [] } ]
    )

    kb_doc = KbDocument.create!(account_id: accounts(:legacy).id, document_uid: SecureRandom.uuid,
                                s3_key: "uploads/topology.pdf")
    batch = WebManualBatch.create!(
      s3_key: "uploads/topology.pdf",
      filename: "topology.pdf",
      sha256: sha,
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      claude_batch_id: "batch_topo",
      claude_batch_ids: %w[batch_topo],
      status: "submitted",
      account_id: accounts(:legacy).id,
      kb_document_id: kb_doc.id,
      page_customs: { 17 => "custom_p17" },
      kept_pages: [ 17 ],
      # Written by SubmitManualBatchJob at submission; comes back out of JSONB
      # with string keys and a string `method`, which is what this pins.
      page_topology_edges: {
        "17" => [
          { "from" => "LIMITADOR", "to" => "CONECTOR AI", "method" => "leader_line",
            "evidence" => "polilínea (485,154)->(405,248) une LIMITADOR con CONECTOR AI" },
          { "from" => "32", "to" => "CERROJOS CABINA", "method" => "vision",
            "evidence" => "conductor naranja que sale de la borna 32 y llega a CERROJOS CABINA" }
        ]
      }
    )

    message = OpenStruct.new(
      model:       "claude-sonnet-4-6",
      content:     [ OpenStruct.new(type: "text", text: page_json) ],
      usage:       FakeUsage.new(input_tokens: 2_000, output_tokens: 900),
      stop_reason: "end_turn"
    )
    fake_batch_client = Object.new
    fake_batch_client.define_singleton_method(:results_each) do |batch_id:, &block|
      block.call(OpenStruct.new(custom_id: "custom_p17",
                                result: OpenStruct.new(type: "succeeded", message: message)))
    end

    uploads = {}
    original_upload = S3DocumentsService.instance_method(:upload_text)
    original_sync   = BulkKbSyncService.instance_method(:sync!)
    S3DocumentsService.define_method(:upload_text) { |key, body| uploads[key] = body }
    BulkKbSyncService.define_method(:sync!) { |**| nil }

    ctx = IngestManualBatchResultsJob.new.send(:context_from_record, batch)
    with_topology_flags do
      IngestManualBatchResultsJob.new.send(:ingest_results, ctx, fake_batch_client, web_manual_batch: batch)
    end

    body = uploads.find { |key, _| key.end_with?("chunk_p17_1.txt") }&.last
    assert body, "expected the page-17 chunk to be written (keys: #{uploads.keys})"
    assert_equal 2, body.scan("RECORD_TYPE: TOPOLOGY_EDGE").size
    assert_includes body, "DERIVATION: leader_line"
    assert_includes body, "DERIVATION: vision"
    assert_includes body, "ACTION: 32 -> CERROJOS CABINA"

    sidecar = JSON.parse(uploads.fetch(uploads.keys.find { |k| k.end_with?("chunk_p17_1.txt.metadata.json") }))
    assert_equal 2, sidecar.fetch("metadataAttributes")["topology_edge_count"]
  ensure
    S3DocumentsService.define_method(:upload_text, original_upload) if defined?(original_upload)
    BulkKbSyncService.define_method(:sync!, original_sync) if defined?(original_sync)
  end

  test "no persisted edges means the chunk body is unchanged, flags on or off" do
    sha = Digest::SHA256.hexdigest("no-topology-manual")
    page_json = JSON.generate(
      "document_name" => "Manual sin topología",
      "aliases"       => [ "Manual" ],
      "chunks"        => [ { "text" => "contenido", "page" => 4, "field_records" => [] } ]
    )

    kb_doc = KbDocument.create!(account_id: accounts(:legacy).id, document_uid: SecureRandom.uuid,
                                s3_key: "uploads/plain.pdf")
    batch = WebManualBatch.create!(
      s3_key: "uploads/plain.pdf", filename: "plain.pdf", sha256: sha,
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      claude_batch_id: "batch_plain", claude_batch_ids: %w[batch_plain], status: "submitted",
      account_id: accounts(:legacy).id, kb_document_id: kb_doc.id,
      page_customs: { 4 => "custom_p4" }, kept_pages: [ 4 ]
    )

    message = OpenStruct.new(
      model: "claude-sonnet-4-6", content: [ OpenStruct.new(type: "text", text: page_json) ],
      usage: FakeUsage.new(input_tokens: 100, output_tokens: 100), stop_reason: "end_turn"
    )
    fake_batch_client = Object.new
    fake_batch_client.define_singleton_method(:results_each) do |batch_id:, &block|
      block.call(OpenStruct.new(custom_id: "custom_p4",
                                result: OpenStruct.new(type: "succeeded", message: message)))
    end

    uploads = {}
    original_upload = S3DocumentsService.instance_method(:upload_text)
    original_sync   = BulkKbSyncService.instance_method(:sync!)
    S3DocumentsService.define_method(:upload_text) { |key, body| uploads[key] = body }
    BulkKbSyncService.define_method(:sync!) { |**| nil }

    ctx = IngestManualBatchResultsJob.new.send(:context_from_record, batch)
    assert_empty ctx[:page_topology_edges]
    with_topology_flags do
      IngestManualBatchResultsJob.new.send(:ingest_results, ctx, fake_batch_client, web_manual_batch: batch)
    end

    body = uploads.find { |key, _| key.end_with?("chunk_p4_1.txt") }&.last
    assert_not_includes body.to_s, "TOPOLOGY_EDGE"
  ensure
    S3DocumentsService.define_method(:upload_text, original_upload) if defined?(original_upload)
    BulkKbSyncService.define_method(:sync!, original_sync) if defined?(original_sync)
  end

  private

  def with_topology_flags
    originals = {
      "INGESTION_LAYOUT_DIGEST_ENABLED" => ENV.fetch("INGESTION_LAYOUT_DIGEST_ENABLED", nil),
      "INGESTION_VISION_TIER_ENABLED"   => ENV.fetch("INGESTION_VISION_TIER_ENABLED", nil)
    }
    originals.each_key { |name| ENV[name] = "true" }
    yield
  ensure
    originals.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end
end
