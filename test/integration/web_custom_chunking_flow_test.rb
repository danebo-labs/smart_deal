# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Integration test for the web custom chunking path (CUSTOM_CHUNKING_WEB_ENABLED=true).
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

    # Enable feature flag
    Rails.application.config.x.custom_chunking_web_enabled = true

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
    Rails.application.config.x.custom_chunking_web_enabled = false
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
  # Flag ON — uses custom chunking pipeline
  # ---------------------------------------------------------------------------

  test "with flag ON: orchestrator uses CustomChunkingPipeline and returns filenames" do
    result = run_pipeline

    assert_includes result, "guide.txt"
  end

  test "with flag ON: chunks are written to S3 with web_v1 ingestion_path" do
    run_pipeline

    sidecar = @fake_s3.uploads.values.find { |v|
      v.is_a?(String) && v.include?("web_v1")
    }
    assert_not_nil sidecar, "expected a sidecar with ingestion_path=web_v1"
    parsed = JSON.parse(sidecar)
    assert_equal "web_v1", parsed["metadataAttributes"]["ingestion_path"]
  end

  test "with flag ON: KbDocument is created for the uploaded file" do
    assert_difference "KbDocument.count", 1 do
      run_pipeline
    end
  end

  test "with flag ON: identity header is written to chunk txt" do
    run_pipeline

    chunk_txt = @fake_s3.uploads.values.find { |v|
      v.is_a?(String) && v.start_with?("[DOCUMENT:")
    }
    assert_not_nil chunk_txt, "expected chunk .txt starting with [DOCUMENT:]"
    assert_includes chunk_txt, "[SEARCH_ALIASES:"
  end

  test "with flag ON: image upload persists KbDocumentThumbnail before chunking" do
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

  test "with flag ON: web_v1_metadata with canonical_name and aliases is passed to BedrockIngestionJob" do
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

  # ---------------------------------------------------------------------------
  # Flag OFF — falls back to legacy path
  # ---------------------------------------------------------------------------

  test "with flag OFF: orchestrator does NOT call BulkKbSyncService" do
    Rails.application.config.x.custom_chunking_web_enabled = false

    kb_sync_called = false
    orig           = KbSyncService.method(:new)
    KbSyncService.define_singleton_method(:new) do |**|
      kb_sync_called = true
      stub = Object.new
      stub.define_singleton_method(:sync!) { |**| nil }
      stub
    end

    run_pipeline
    assert kb_sync_called, "expected KbSyncService (legacy) to be called when flag is OFF"
  ensure
    KbSyncService.define_singleton_method(:new, orig) if defined?(orig)
  end

  # ---------------------------------------------------------------------------
  # Fallback on error
  # ---------------------------------------------------------------------------

  test "with flag ON: falls back to KbSyncService when Anthropic raises" do
    Anthropic::Client.define_singleton_method(:new) do |**|
      client = OpenStruct.new(api_key: "fake")
      msgs   = OpenStruct.new
      msgs.define_singleton_method(:stream) { |_| raise Anthropic::Errors::APIError.new(url: "https://api.anthropic.com/v1/messages", status: 529, body: { error: "overloaded" }) }
      client.define_singleton_method(:messages) { msgs }
      client
    end

    fallback_called = false
    orig_ks         = KbSyncService.method(:new)
    KbSyncService.define_singleton_method(:new) do |**|
      fallback_called = true
      stub = Object.new
      stub.define_singleton_method(:sync!) { |**| nil }
      stub
    end

    # Disable no-fallback mode so the rescue path runs instead of re-raising
    orig_no_fallback = ENV["CUSTOM_CHUNKING_NO_FALLBACK"]
    ENV["CUSTOM_CHUNKING_NO_FALLBACK"] = "false"

    result = run_pipeline
    assert fallback_called, "expected KbSyncService fallback when Anthropic fails"
    assert_includes result, "guide.txt"
  ensure
    ENV["CUSTOM_CHUNKING_NO_FALLBACK"] = orig_no_fallback
    KbSyncService.define_singleton_method(:new, orig_ks) if defined?(orig_ks)
  end
end
