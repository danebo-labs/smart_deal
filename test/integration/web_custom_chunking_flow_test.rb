# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Integration test for the web custom chunking path.
# Verifies the complete flow from QueryOrchestratorService#upload_and_sync_attachments
# through CustomChunkingPipeline → SingleFileChunkingService → BatchResultsParserService
# without making real Anthropic or AWS calls.
class WebCustomChunkingFlowTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Fakes
  # ---------------------------------------------------------------------------

  class FakeAnthropicMessages
    def initialize(response_json:) = (@response_json = response_json)

    def stream(_)
      content  = [ OpenStruct.new(type: "text", text: @response_json) ]
      usage    = OpenStruct.new(input_tokens: 50, output_tokens: 100,
                                cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
      message  = OpenStruct.new(content: content, usage: usage, model: "claude-opus-4-7")
      OpenStruct.new(accumulated_message: message)
    end
  end

  class FakeAnthropicClient
    attr_reader :messages, :api_key

    def initialize(response_json:)
      @messages = FakeAnthropicMessages.new(response_json: response_json)
      @api_key  = "fake"
    end
  end

  class FakeS3
    attr_reader :uploads, :upload_calls

    def initialize
      @uploads      = {}
      @upload_calls = []
    end

    def upload_file(filename, _binary, _content_type)
      key = "uploads/#{Date.current.iso8601}/#{filename}"
      @upload_calls << filename
      key
    end

    def upload_text(key, content)
      @uploads[key] = content
      key
    end
  end

  # ---------------------------------------------------------------------------
  # Shared fixture
  # ---------------------------------------------------------------------------

  DOC_NAME = "Elevator Safety Guide"
  ALIASES  = %w[safety guide elevator]

  def golden_response_json
    {
      "document_name" => DOC_NAME,
      "aliases"       => ALIASES,
      "chunks"        => [
        {
          "text" => "# S0 — DOCUMENT IDENTIFICATION\nTechnical content.",
          "page" => 1
        }
      ]
    }.to_json
  end

  # ---------------------------------------------------------------------------
  # Setup / Teardown
  # ---------------------------------------------------------------------------

  setup do
    @fake_s3       = FakeS3.new
    self_ref       = self

    # Stub Anthropic::Client
    @orig_anthropic_new = Anthropic::Client.method(:new)
    Anthropic::Client.define_singleton_method(:new) do |**|
      FakeAnthropicClient.new(response_json: self_ref.golden_response_json)
    end

    # Stub S3DocumentsService
    @orig_s3_new = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { self_ref.instance_variable_get(:@fake_s3) }

    # Stub PdfImageDetector
    @orig_image_pages = PdfImageDetector.method(:image_pages)
    PdfImageDetector.define_singleton_method(:image_pages) { |_| Set.new }

    # Stub BulkKbSyncService#sync!
    @orig_bulk_sync_new = BulkKbSyncService.method(:new)
    BulkKbSyncService.define_singleton_method(:new) do
      svc = Object.new
      svc.define_singleton_method(:sync!) { |**| { job_id: "jid-123", kb_id: "VBB72VKABV", data_source_id: "8DUTRUCDTS" } }
      svc
    end

    # Suppress BedrockIngestionJob
    @orig_bedrock_job = BedrockIngestionJob.method(:perform_later)
    BedrockIngestionJob.define_singleton_method(:perform_later) { |*| nil }

    # Suppress TrackBedrockQueryJob
    @orig_tbq = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    ENV["KNOWLEDGE_BASE_S3_BUCKET"] = "test-bucket"
  end

  teardown do
    Anthropic::Client.define_singleton_method(:new, @orig_anthropic_new)
    S3DocumentsService.define_singleton_method(:new, @orig_s3_new)
    PdfImageDetector.define_singleton_method(:image_pages, @orig_image_pages)
    BulkKbSyncService.define_singleton_method(:new, @orig_bulk_sync_new)
    BedrockIngestionJob.define_singleton_method(:perform_later, @orig_bedrock_job)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, @orig_tbq)
    ENV.delete("KNOWLEDGE_BASE_S3_BUCKET")
  end

  # ---------------------------------------------------------------------------
  # Helper
  # ---------------------------------------------------------------------------

  def run_pipeline(filename: "guide.txt", content_type: "text/plain")
    binary = "Sample file content for #{filename}"
    doc_payload = [ {
      filename:   filename,
      data:       Base64.strict_encode64(binary),
      media_type: content_type
    } ]
    # Inject as documents hash with symbol keys
    doc_payload = doc_payload.map(&:to_h)

    orchestrator = QueryOrchestratorService.new("any query", documents: doc_payload)
    orchestrator.send(:upload_and_sync_attachments)
  end

  def run_pipeline_image(filename: "photo.jpg", content_type: "image/jpeg")
    binary       = "fake-image-bytes-#{filename}"
    thumb_binary = "fake-thumb-jpeg"
    image_attrs  = [ {
      filename:               filename,
      data:                   Base64.strict_encode64(binary),
      binary:                 binary,
      media_type:             content_type,
      thumbnail_binary:       thumb_binary,
      thumbnail_content_type: "image/jpeg",
      thumbnail_width:        88,
      thumbnail_height:       66
    } ]

    orchestrator = QueryOrchestratorService.new("any query", images: image_attrs)
    orchestrator.send(:upload_and_sync_attachments)
  end

  # ---------------------------------------------------------------------------
  # Custom chunking pipeline flow
  # ---------------------------------------------------------------------------

  test "orchestrator uses CustomChunkingPipeline and returns filenames" do
    result = run_pipeline

    assert_includes result, "guide.txt"
  end

  test "chunks are written to S3 with web_v1 ingestion_path" do
    run_pipeline

    sidecar = @fake_s3.uploads.values.find { |v|
      v.is_a?(String) && v.include?("web_v1")
    }
    assert_not_nil sidecar, "expected a sidecar with ingestion_path=web_v1"
    parsed = JSON.parse(sidecar)
    assert_equal "web_v1", parsed["metadataAttributes"]["ingestion_path"]
  end

  test "KbDocument is created for the uploaded file" do
    assert_difference "KbDocument.count", 1 do
      run_pipeline
    end
  end

  test "identity header is written to chunk txt" do
    run_pipeline

    chunk_txt = @fake_s3.uploads.values.find { |v|
      v.is_a?(String) && v.start_with?("[DOCUMENT:")
    }
    assert_not_nil chunk_txt, "expected chunk .txt starting with [DOCUMENT:]"
    assert_includes chunk_txt, "[SEARCH_ALIASES:"
  end

  test "image upload persists KbDocumentThumbnail before chunking" do
    assert_difference "KbDocument.count", 1 do
      assert_difference "KbDocumentThumbnail.count", 1 do
        run_pipeline_image
      end
    end

    kb = KbDocument.order(created_at: :desc).first
    assert_not_nil kb.thumbnail
    assert_equal "fake-thumb-jpeg", kb.thumbnail.data
    assert_equal 88, kb.thumbnail.width
    assert_equal 66, kb.thumbnail.height
  end

  test "web_v1_metadata with canonical_name and aliases is passed to BedrockIngestionJob" do
    job_kwargs_captured = nil
    orig_later = BedrockIngestionJob.method(:perform_later)
    BedrockIngestionJob.define_singleton_method(:perform_later) do |*_args, **kwargs|
      job_kwargs_captured = kwargs
      nil
    end

    run_pipeline(filename: "guide.txt", content_type: "text/plain")

    assert_not_nil job_kwargs_captured, "BedrockIngestionJob must be enqueued"
    metadata = job_kwargs_captured[:web_v1_metadata]
    assert_not_nil metadata, "web_v1_metadata must be present in job kwargs"
    assert_equal 1, metadata.size
    entry = metadata.first
    assert_equal "guide.txt", entry["filename"]
    assert_equal DOC_NAME,    entry["canonical_name"]
    assert_equal ALIASES,     entry["aliases"]
  ensure
    BedrockIngestionJob.define_singleton_method(:perform_later, orig_later)
  end

  test "web chat PDF upload without question parses sync and does not enqueue manual batch" do
    orig_submit_manual = SubmitManualBatchJob.method(:perform_later)
    orig_sfc_new       = SingleFileChunkingService.method(:new)
    orig_splitter_new  = PdfPageSplitterService.method(:new)

    batch_calls = []
    sfc_calls   = []

    SubmitManualBatchJob.define_singleton_method(:perform_later) do |**kwargs|
      batch_calls << kwargs
    end

    fake_splitter = Object.new
    fake_splitter.define_singleton_method(:page_count) { CustomChunkingPipeline::SYNC_PAGES + 3 }
    PdfPageSplitterService.define_singleton_method(:new) { |_binary| fake_splitter }

    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      sfc_calls << kwargs
      asset = ChunkAsset.new(
        filename: kwargs[:filename],
        sha256: kwargs[:sha256],
        s3_key: kwargs[:s3_key],
        content_type: kwargs[:content_type]
      )
      asset.canonical_name = DOC_NAME
      asset.aliases        = ALIASES
      OpenStruct.new(call: asset)
    end

    binary = "%PDF long manual bytes"
    doc_payload = [ {
      filename: "long_manual.pdf",
      data: Base64.strict_encode64(binary),
      media_type: "application/pdf"
    } ]

    QueryOrchestratorService
      .new("", documents: doc_payload)
      .send(:upload_and_sync_attachments)

    assert_empty batch_calls, "web/chat uploads must not enqueue SubmitManualBatchJob"
    assert_equal 1, sfc_calls.size, "long PDFs from web/chat must parse sync"
    assert_equal "long_manual.pdf", sfc_calls.first[:filename]
  ensure
    SubmitManualBatchJob.define_singleton_method(:perform_later, orig_submit_manual)
    SingleFileChunkingService.define_singleton_method(:new, orig_sfc_new)
    PdfPageSplitterService.define_singleton_method(:new, orig_splitter_new)
  end

  # ---------------------------------------------------------------------------
  # Office parse error — no legacy fallback
  # ---------------------------------------------------------------------------

  test "Office file: SingleFileChunkingService failure does NOT call KbSyncService (legacy)" do
    orig_convert = OfficeToPdfConverter.method(:convert)
    OfficeToPdfConverter.define_singleton_method(:convert) { |_, **| raise OfficeToPdfConverter::Error, "LibreOffice not found" }

    legacy_called  = false
    orig_kb        = KbSyncService.method(:new)
    KbSyncService.define_singleton_method(:new) do |**|
      legacy_called = true
      stub = Object.new
      stub.define_singleton_method(:sync!) { |**| nil }
      stub
    end

    broadcaster_failed_called = false
    orig_failed = KbSyncBroadcaster.method(:failed)
    KbSyncBroadcaster.define_singleton_method(:failed) do |**|
      broadcaster_failed_called = true
    end

    binary = "PK fake pptx bytes"
    doc_payload = [ {
      filename:   "deck.pptx",
      data:       Base64.strict_encode64(binary),
      media_type: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    } ]

    orchestrator = QueryOrchestratorService.new("any query", documents: doc_payload)
    orchestrator.send(:upload_and_sync_attachments)

    assert_not legacy_called,          "KbSyncService (legacy) must NOT be called for Office parse failures"
    assert     broadcaster_failed_called, "KbSyncBroadcaster.failed must be called to notify the user"
  ensure
    OfficeToPdfConverter.define_singleton_method(:convert, orig_convert)
    KbSyncService.define_singleton_method(:new, orig_kb) if defined?(orig_kb)
    KbSyncBroadcaster.define_singleton_method(:failed, orig_failed) if defined?(orig_failed)
  end
end
