# frozen_string_literal: true

require "test_helper"

class IngestBatchResultsJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  # ── Fakes ─────────────────────────────────────────────────────────────────────

  FakeUsage = Struct.new(:input_tokens, :output_tokens,
                          :cache_read_input_tokens, :cache_creation_input_tokens,
                          keyword_init: true)

  FakeMessage = Struct.new(:model, :content, :usage, keyword_init: true)
  FakeResult  = Struct.new(:type, :message, keyword_init: true)
  FakeBatchResult = Struct.new(:custom_id, :result, keyword_init: true)

  class FakeBatchClient
    attr_accessor :results

    def initialize(results = [])
      @results = results
    end

    def results_each(batch_id:)
      @results.each { |r| yield r }
    end
  end

  # ── Constants ─────────────────────────────────────────────────────────────────

  PHOTO_JSON = JSON.generate({
    "canonical_component" => "Motor Drive Unit",
    "manufacturer" => "Orona",
    "model" => "MDU-3000",
    "subsystem" => "MOTOR_DRIVE",
    "condition" => "GOOD",
    "aliases" => [ "MDU-3000", "Orona motor" ],
    "summary" => "Motor drive unit in good condition.",
    "anti_hallucination_notes" => "Manufacturer visible."
  })

  PAGE1_JSON = JSON.generate({
    "document_name" => "Orona ARCA II Manual",
    "aliases" => [ "ARCA II" ],
    "summary" => "Manual.",
    "companion_offer" => "Pregunta.",
    "chunks" => [ { "text" => "S0 page 1 content", "page" => 1, "field_records" => [] } ]
  })

  PAGE2_JSON = JSON.generate({
    "document_name" => "Orona ARCA II Manual",
    "aliases" => [ "ARCA II", "installation" ],
    "summary" => "Parte 2.",
    "companion_offer" => "Cualquier duda.",
    "chunks" => [ { "text" => "S16 page 2 content", "page" => 2, "field_records" => [] } ]
  })

  def make_usage(input: 100, output: 50, cache_read: 10, cache_creation: 5)
    FakeUsage.new(
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cache_read,
      cache_creation_input_tokens: cache_creation
    )
  end

  def make_message(json, model: "claude-sonnet-4-6", usage: nil)
    FakeMessage.new(
      model:   model,
      content: [ OpenStruct.new(type: "text", text: json) ],
      usage:   usage || make_usage
    )
  end

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    @orig_upload_text  = S3DocumentsService.instance_method(:upload_text)
    @orig_sync         = BulkKbSyncService.instance_method(:sync!)
    @orig_client_new   = ClaudeBatchClient.method(:new)

    S3DocumentsService.define_method(:upload_text) { |_key, _body| nil }
    BulkKbSyncService.define_method(:sync!) { |**| { job_id: "test-job-123" } }

    @fake_client = FakeBatchClient.new
    _fc = @fake_client  # captured by closure; not resolved via receiver
    ClaudeBatchClient.define_singleton_method(:new) { _fc }

    # Suppress PollBulkBedrockIngestionJob (OpenStruct.perform_later: nil is not callable)
    @orig_poll_set = PollBulkBedrockIngestionJob.method(:set)
    noop_poll = Class.new do
      def self.perform_later(*); end
    end
    PollBulkBedrockIngestionJob.define_singleton_method(:set) { |**| noop_poll }
  end

  teardown do
    S3DocumentsService.define_method(:upload_text, @orig_upload_text)
    BulkKbSyncService.define_method(:sync!, @orig_sync)
    ClaudeBatchClient.singleton_class.remove_method(:new) rescue nil
    PollBulkBedrockIngestionJob.define_singleton_method(:set, @orig_poll_set)
  end

  # ── Helper ─────────────────────────────────────────────────────────────────────

  def create_bulk_with_assets
    bulk = BulkUpload.create!(
      sha256: Digest::SHA256.hexdigest("bulk_#{SecureRandom.hex(8)}"),
      original_filename: "mixed.zip",
      status: "processing",
      claude_batch_id: "msgbatch_test_001"
    )

    sha_photo = Digest::SHA256.hexdigest("photo_binary")
    sha_pdf   = Digest::SHA256.hexdigest("pdf_binary")

    photo_asset = BulkUploadAsset.create!(
      bulk_upload:    bulk,
      custom_id:      sha_photo[0, 32],
      sha256:         sha_photo,
      s3_key:         "bulk_uploads/photo.jpg",
      filename:       "photo.jpg",
      content_type:   "image/jpeg",
      status:         "in_batch",
      ingestion_path: "field_photo_v1"
    )

    pdf_sha_prefix = sha_pdf[0, 16]
    pdf_asset = BulkUploadAsset.create!(
      bulk_upload:      bulk,
      custom_id:        sha_pdf[0, 32],
      sha256:           sha_pdf,
      s3_key:           "bulk_uploads/manual.pdf",
      filename:         "manual.pdf",
      content_type:     "application/pdf",
      status:           "in_batch",
      ingestion_path:   "manual_batch_v1",
      batch_custom_ids: [ "#{pdf_sha_prefix}_p1", "#{pdf_sha_prefix}_p2" ]
    )

    [ bulk, photo_asset, pdf_asset, pdf_sha_prefix ]
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

  test "track_asset_usage skips when message has no usage" do
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      job   = IngestBatchResultsJob.new
      asset = Object.new
      asset.define_singleton_method(:update_columns) { |_| flunk("should not update") }
      msg = Struct.new(:content).new([])
      job.send(:track_asset_usage, asset, msg, user_query: "test", ingestion_path: "batch_v1")
    end
  end

  test "photo → field_photo_v1 parsed; PDF pages merged → manual_batch_v1 parsed" do
    bulk, photo_asset, pdf_asset, pdf_sha_prefix = create_bulk_with_assets

    @fake_client.results = [
      FakeBatchResult.new(
        custom_id: photo_asset.custom_id,
        result:    FakeResult.new(type: "succeeded", message: make_message(PHOTO_JSON))
      ),
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p1",
        result:    FakeResult.new(type: "succeeded", message: make_message(PAGE1_JSON))
      ),
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p2",
        result:    FakeResult.new(type: "succeeded",
                                 message: make_message(PAGE2_JSON, usage: make_usage(input: 200, output: 80)))
      )
    ]

    IngestBatchResultsJob.perform_now(bulk.id)

    photo_asset.reload
    pdf_asset.reload

    assert_equal "syncing",          photo_asset.status
    assert_equal "Motor Drive Unit", photo_asset.canonical_name

    assert_equal "syncing",               pdf_asset.status
    assert_equal "Orona ARCA II Manual",  pdf_asset.canonical_name

    # PDF tokens: accumulate page1 (100+10+5=115) + page2 (200+10+5=215) = 330
    assert_equal 115 + 215, pdf_asset.claude_input_tokens
    assert_equal 50  + 80,  pdf_asset.claude_output_tokens
  ensure
    bulk&.bulk_upload_assets&.destroy_all
    bulk&.destroy
  end

  test "TrackBedrockQueryJob emitted with -batch suffix for PDF pages" do
    bulk, _photo_asset, pdf_asset, pdf_sha_prefix = create_bulk_with_assets

    # Only PDF pages — skip photo for this assertion
    @fake_client.results = [
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p1",
        result:    FakeResult.new(type: "succeeded", message: make_message(PAGE1_JSON))
      ),
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p2",
        result:    FakeResult.new(type: "succeeded", message: make_message(PAGE2_JSON))
      )
    ]

    IngestBatchResultsJob.perform_now(bulk.id)

    tracking = enqueued_jobs
      .select { |j| j[:job] == TrackBedrockQueryJob }
      .map { |j| j[:args].first }

    assert tracking.any? { |a| a["model_id"]&.end_with?("-batch") },
           "Expected at least one TrackBedrockQueryJob with -batch model_id"
    assert tracking.any? { |a| a["user_query"]&.start_with?("bulk_batch:") },
           "Expected user_query to start with 'bulk_batch:'"
  ensure
    bulk&.bulk_upload_assets&.destroy_all
    bulk&.destroy
  end

  test "batch page rows carry route, attempt 1, 8k cap and page correlation_id (I0)" do
    bulk, _photo_asset, pdf_asset, pdf_sha_prefix = create_bulk_with_assets

    @fake_client.results = [
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p1",
        result:    FakeResult.new(type: "succeeded", message: make_message(PAGE1_JSON))
      ),
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p2",
        result:    FakeResult.new(type: "succeeded", message: make_message(PAGE2_JSON))
      )
    ]

    IngestBatchResultsJob.perform_now(bulk.id)

    tracking = enqueued_jobs
      .select { |j| j[:job] == TrackBedrockQueryJob }
      .map { |j| j[:args].first }
      .select { |a| a["user_query"].to_s.start_with?("bulk_batch:") }
      .sort_by { |a| a["user_query"] }

    assert_equal 2, tracking.size
    expected_prefix = "ingest:#{pdf_asset.sha256[0, 12]}"
    tracking.each_with_index do |args, idx|
      assert_equal "batch",                              args["route"]
      assert_equal 1,                                    args["attempt"]
      assert_equal BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS, args["max_tokens"]
      assert_equal "#{expected_prefix}:p#{idx + 1}",     args["correlation_id"]
    end
  ensure
    bulk&.bulk_upload_assets&.destroy_all
    bulk&.destroy
  end

  test "retry ladder escalates 16k → 32k while truncated, attempts 2 and 3 share correlation (O3')" do
    bulk, _photo_asset, pdf_asset, = create_bulk_with_assets
    initial_usage = make_usage(input: 100, output: 8_000, cache_read: 10, cache_creation: 5)
    retry_usage_1 = make_usage(input: 120, output: 16_000, cache_read: 0, cache_creation: 0)
    retry_usage_2 = make_usage(input: 130, output: 9_000,  cache_read: 0, cache_creation: 0)
    page_results = [ {
      page_number: 1,
      text: PAGE1_JSON,
      model: "claude-sonnet-4-6",
      usage: initial_usage,
      stop_reason: "max_tokens"
    } ]

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:get_object) { |**| OpenStruct.new(body: StringIO.new("pdf")) }
    fake_splitter = Object.new
    fake_splitter.define_singleton_method(:each_page) { |&block| block.call(1, "page-pdf") }

    calls = []
    usages = [ retry_usage_1, retry_usage_2 ]
    fake_retry_client = Object.new
    fake_retry_client.define_singleton_method(:call) do |**kwargs|
      calls << kwargs
      # First retry still truncated; second one fits.
      stop = calls.size == 1 ? "max_tokens" : nil
      { text: PAGE1_JSON, usage: usages[calls.size - 1], stop_reason: stop }
    end

    original_s3_new           = Aws::S3::Client.method(:new)
    original_splitter_new     = PdfPageSplitterService.method(:new)
    original_retry_client_new = ClaudeChunkingClient.method(:new)
    Aws::S3::Client.define_singleton_method(:new) { |*_, **_| fake_s3 }
    PdfPageSplitterService.define_singleton_method(:new) { |_| fake_splitter }
    ClaudeChunkingClient.define_singleton_method(:new) { |**_| fake_retry_client }

    result = IngestBatchResultsJob.new.send(:retry_truncated_pages!, pdf_asset, page_results)

    assert_equal 2, calls.size, "expected 16k retry then 32k escalation"
    assert_equal [ BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS, BatchChunkingPrompt::MAX_TOKENS ],
                 calls.pluck(:max_tokens)
    assert_equal [ 2, 3 ],                       calls.pluck(:attempt)
    assert_equal %w[bulk_retry bulk_retry],      calls.pluck(:route)
    expected_correlation = "ingest:#{pdf_asset.sha256[0, 12]}:p1"
    assert calls.all? { |c| c[:correlation_id] == expected_correlation },
           "all retry attempts must share the page correlation_id"

    # Batch usage preserved; both retries accumulated on the asset.
    assert_same initial_usage, result.first[:usage]
    assert_equal 120 + 130, pdf_asset.reload.claude_input_tokens
    assert_equal 16_000 + 9_000, pdf_asset.claude_output_tokens
    assert_nil result.first[:stop_reason]
  ensure
    Aws::S3::Client.define_singleton_method(:new, original_s3_new) if defined?(original_s3_new)
    PdfPageSplitterService.define_singleton_method(:new, original_splitter_new) if defined?(original_splitter_new)
    ClaudeChunkingClient.define_singleton_method(:new, original_retry_client_new) if defined?(original_retry_client_new)
    bulk&.bulk_upload_assets&.destroy_all
    bulk&.destroy
  end

  test "retry ladder stops at 16k when no longer truncated (single retry call)" do
    bulk, _photo_asset, pdf_asset, = create_bulk_with_assets
    page_results = [ {
      page_number: 1,
      text: PAGE1_JSON,
      model: "claude-sonnet-4-6",
      usage: make_usage(input: 100, output: 8_000),
      stop_reason: "max_tokens"
    } ]

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:get_object) { |**| OpenStruct.new(body: StringIO.new("pdf")) }
    fake_splitter = Object.new
    fake_splitter.define_singleton_method(:each_page) { |&block| block.call(1, "page-pdf") }

    calls = []
    usage_for_retry = make_usage(input: 120, output: 5_000, cache_read: 0, cache_creation: 0)
    fake_retry_client = Object.new
    fake_retry_client.define_singleton_method(:call) do |**kwargs|
      calls << kwargs
      { text: PAGE1_JSON, usage: usage_for_retry, stop_reason: nil }
    end

    original_s3_new           = Aws::S3::Client.method(:new)
    original_splitter_new     = PdfPageSplitterService.method(:new)
    original_retry_client_new = ClaudeChunkingClient.method(:new)
    Aws::S3::Client.define_singleton_method(:new) { |*_, **_| fake_s3 }
    PdfPageSplitterService.define_singleton_method(:new) { |_| fake_splitter }
    ClaudeChunkingClient.define_singleton_method(:new) { |**_| fake_retry_client }

    IngestBatchResultsJob.new.send(:retry_truncated_pages!, pdf_asset, page_results)

    assert_equal 1, calls.size, "no 32k escalation when 16k retry fits"
    assert_equal BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS, calls.first[:max_tokens]
  ensure
    Aws::S3::Client.define_singleton_method(:new, original_s3_new) if defined?(original_s3_new)
    PdfPageSplitterService.define_singleton_method(:new, original_splitter_new) if defined?(original_splitter_new)
    ClaudeChunkingClient.define_singleton_method(:new, original_retry_client_new) if defined?(original_retry_client_new)
    bulk&.bulk_upload_assets&.destroy_all
    bulk&.destroy
  end

  test "truncated batch retry keeps original batch usage and does not enqueue duplicate tracking" do
    bulk, _photo_asset, pdf_asset, = create_bulk_with_assets
    initial_usage = make_usage(input: 100, output: 4_000, cache_read: 10, cache_creation: 5)
    retry_usage = make_usage(input: 120, output: 5_000, cache_read: 20, cache_creation: 6)
    page_results = [ {
      page_number: 1,
      text: PAGE1_JSON,
      model: "claude-sonnet-4-6",
      usage: initial_usage,
      stop_reason: "max_tokens"
    } ]

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:get_object) do |**|
      OpenStruct.new(body: StringIO.new("pdf"))
    end

    fake_splitter = Object.new
    fake_splitter.define_singleton_method(:each_page) do |&block|
      block.call(1, "page-pdf")
    end

    call_args = nil
    fake_retry_client = Object.new
    fake_retry_client.define_singleton_method(:call) do |**kwargs|
      call_args = kwargs
      { text: PAGE1_JSON, usage: retry_usage, stop_reason: nil }
    end

    original_s3_new = Aws::S3::Client.method(:new)
    original_splitter_new = PdfPageSplitterService.method(:new)
    original_retry_client_new = ClaudeChunkingClient.method(:new)
    Aws::S3::Client.define_singleton_method(:new) { |*args, **kwargs| fake_s3 }
    PdfPageSplitterService.define_singleton_method(:new) { |_binary| fake_splitter }
    ClaudeChunkingClient.define_singleton_method(:new) { |**_kwargs| fake_retry_client }

    result = nil
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      result = IngestBatchResultsJob.new.send(
        :retry_truncated_pages!,
        pdf_asset,
        page_results
      )
    end

    assert_equal "bulk_retry", call_args[:tracking_prefix]
    assert_same initial_usage, result.first[:usage]
    assert_equal 120 + 20 + 6, pdf_asset.reload.claude_input_tokens
    assert_equal 5_000, pdf_asset.claude_output_tokens
  ensure
    Aws::S3::Client.define_singleton_method(:new, original_s3_new) if defined?(original_s3_new)
    PdfPageSplitterService.define_singleton_method(:new, original_splitter_new) if defined?(original_splitter_new)
    ClaudeChunkingClient.define_singleton_method(:new, original_retry_client_new) if defined?(original_retry_client_new)
    bulk&.bulk_upload_assets&.destroy_all
    bulk&.destroy
  end
end
