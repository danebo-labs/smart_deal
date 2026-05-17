# frozen_string_literal: true

require "test_helper"
require "ostruct"

class SingleFileChunkingServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Shared fixtures
  # ---------------------------------------------------------------------------

  DOC_NAME = "Orona Hydraulic Manual"
  ALIASES  = %w[HPM-400 orona hydraulic]

  def golden_json
    {
      "document_name" => DOC_NAME,
      "aliases"       => ALIASES,
      "chunks"        => [
        {
          "text" => "# S0 — DOCUMENT IDENTIFICATION\nContent here.",
          "page" => 1
        }
      ]
    }.to_json
  end

  # ---------------------------------------------------------------------------
  # Fakes
  # ---------------------------------------------------------------------------

  class FakeS3Service
    attr_reader :uploads

    def initialize = (@uploads = {})
    def upload_text(key, content) = (@uploads[key] = content; key)
  end

  class FakeAnthropicMessages
    def initialize(response_text:) = (@response_text = response_text)

    def stream(_params)
      content  = [ OpenStruct.new(type: "text", text: @response_text) ]
      usage    = OpenStruct.new(
        input_tokens: 100, output_tokens: 200,
        cache_read_input_tokens: 0, cache_creation_input_tokens: 0
      )
      message  = OpenStruct.new(content: content, usage: usage, model: "claude-opus-4-7")
      OpenStruct.new(accumulated_message: message)
    end
  end

  class FakeAnthropicClient
    attr_reader :messages, :api_key

    def initialize(response_text:)
      @messages = FakeAnthropicMessages.new(response_text: response_text)
      @api_key  = "fake"
    end
  end

  # ---------------------------------------------------------------------------
  # Setup / Teardown
  # ---------------------------------------------------------------------------

  setup do
    @fake_s3       = FakeS3Service.new
    @response_json = golden_json
    self_ref       = self

    # Stub Anthropic::Client
    @orig_anthropic_new = Anthropic::Client.method(:new)
    Anthropic::Client.define_singleton_method(:new) do |**|
      FakeAnthropicClient.new(response_text: self_ref.instance_variable_get(:@response_json))
    end

    # Stub PdfImageDetector to report no images (text-only PDF path by default)
    @orig_image_pages = PdfImageDetector.method(:image_pages)
    PdfImageDetector.define_singleton_method(:image_pages) { |_| Set.new }

    # Suppress TrackBedrockQueryJob
    @orig_tbq_later = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    ENV["KNOWLEDGE_BASE_S3_BUCKET"] = "test-bucket"
  end

  teardown do
    Anthropic::Client.define_singleton_method(:new, @orig_anthropic_new)
    PdfImageDetector.define_singleton_method(:image_pages, @orig_image_pages)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, @orig_tbq_later)
    ENV.delete("KNOWLEDGE_BASE_S3_BUCKET")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def build_service(filename: "pump.pdf", content_type: "application/pdf", binary: "%PDF-1.4")
    SingleFileChunkingService.new(
      binary:       binary,
      content_type: content_type,
      filename:     filename,
      s3_key:       "uploads/2026-01-01/#{filename}",
      sha256:       Digest::SHA256.hexdigest(binary),
      s3_service:   @fake_s3
    )
  end

  # ---------------------------------------------------------------------------
  # Happy paths
  # ---------------------------------------------------------------------------

  test "text/plain file: writes chunks to S3 with correct canonical_name" do
    asset = build_service(filename: "note.txt", content_type: "text/plain", binary: "hello world").call

    assert_equal DOC_NAME, asset.canonical_name
    assert_equal ALIASES,  asset.aliases
    assert_equal 1,        asset.chunks_count
    assert_not_nil             asset.chunks_s3_prefix
    assert_not_empty           @fake_s3.uploads
  end

  test "application/pdf text-only: routes to pdf_text_only and writes chunks" do
    asset = build_service.call

    assert_equal DOC_NAME, asset.canonical_name
    assert_operator 1, :<=, @fake_s3.uploads.count
  end

  test "image/jpeg: writes chunks" do
    asset = build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call
    assert_equal DOC_NAME, asset.canonical_name
  end

  test "ingestion_path is web_v1 in sidecar metadataAttributes" do
    build_service.call

    sidecar_key = @fake_s3.uploads.keys.find { |k| k.end_with?(".metadata.json") }
    assert_not_nil sidecar_key, "expected at least one .metadata.json sidecar"
    attrs = JSON.parse(@fake_s3.uploads[sidecar_key])["metadataAttributes"]
    assert_equal "web_v1", attrs["ingestion_path"]
  end

  test "alias fallback fires when Claude returns empty aliases" do
    @response_json = {
      "document_name" => DOC_NAME,
      "aliases"       => [],
      "chunks"        => [
        {
          "text" => "# S0 content",
          "page" => 1
        }
      ]
    }.to_json

    asset = build_service(filename: "orona-pump-manual.pdf").call

    assert_includes asset.aliases, "orona"
    assert_includes asset.aliases, "pump"
    assert_includes asset.aliases, "manual"
  end

  # ---------------------------------------------------------------------------
  # Office conversion path
  # ---------------------------------------------------------------------------

  test "office extension triggers OfficeToPdfConverter before routing" do
    orig_convert = OfficeToPdfConverter.method(:convert)
    OfficeToPdfConverter.define_singleton_method(:convert) { |_, **| "%PDF-1.4 fake" }

    asset = build_service(filename: "report.docx", content_type: "application/octet-stream", binary: "PK fake").call
    assert_equal DOC_NAME, asset.canonical_name
  ensure
    OfficeToPdfConverter.define_singleton_method(:convert, orig_convert)
  end

  # ─── pdf_mixed: two-wave identity hint ────────────────────────────────────────

  # Invariant: 1 upload = 1 identity, regardless of N Claude calls.
  # Wave A (anchor page) establishes document_name; wave B pages receive it as a hint
  # so Claude emits a consistent document_name across all parts of the same file.
  test "pdf_mixed: wave-B pages receive document_name_hint from wave-A response" do
    FakePdfPage = Struct.new(:number, :binary, :model, :force_opus) unless defined?(FakePdfPage)

    page1 = FakePdfPage.new(1, "%PDF-fake-p1", BatchChunkingPrompt::MODEL_MULTIMODAL, false)
    page3 = FakePdfPage.new(3, "%PDF-fake-p3", BatchChunkingPrompt::MODEL_MULTIMODAL, false)

    orig_classify = FileMultimodalRouter.method(:classify)
    FileMultimodalRouter.define_singleton_method(:classify) do |**|
      OpenStruct.new(mode: :pdf_mixed, pages: [ page1, page3 ])
    end

    orig_prf_new = PageRelevanceFilter.method(:new)
    PageRelevanceFilter.define_singleton_method(:new) do |*|
      OpenStruct.new(call: { keep: true, reason: "test", source: "stub" })
    end

    page1_json = { "document_name" => "Anchor Manual", "aliases" => %w[anchor], "chunks" => [ { "text" => "# S0", "page" => 1 } ] }.to_json
    page3_json = { "document_name" => "Anchor Manual", "aliases" => %w[manual],  "chunks" => [ { "text" => "# S4", "page" => 3 } ] }.to_json

    mutex          = Mutex.new
    captured_texts = []
    responses      = [ page1_json, page3_json ]
    call_count     = 0

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        text_block = Array(params.dig(:messages)&.find { |m| m[:role] == "user" }&.dig(:content))
                       .select { |b| b.is_a?(Hash) && b[:type] == "text" }
                       .map { |b| b[:text] }
                       .join(" ")
        idx = mutex.synchronize { call_count.tap { call_count += 1 } }
        mutex.synchronize { captured_texts << text_block }
        response_text = responses[idx] || responses.last
        content  = [ OpenStruct.new(type: "text", text: response_text) ]
        usage    = OpenStruct.new(input_tokens: 100, output_tokens: 200,
                                  cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message  = OpenStruct.new(content: content, usage: usage, model: "claude-opus-4-7")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    asset = build_service(filename: "manual.pdf").call

    assert_equal 2, captured_texts.size, "expected exactly 2 Claude calls (wave A + wave B)"
    assert_not_includes captured_texts[0], "Document name hint:", "wave A must not receive a hint"
    assert_includes     captured_texts[1], "Anchor Manual",       "wave B must receive document_name_hint"
    assert_equal "Anchor Manual", asset.canonical_name
  ensure
    FileMultimodalRouter.define_singleton_method(:classify, orig_classify)
    PageRelevanceFilter.define_singleton_method(:new, orig_prf_new)
  end

  # ─── Image summary + locale ──────────────────────────────────────────────────

  test "image mode: locale is forwarded as 'Summary language' text-block" do
    captured_text_blocks = []
    golden_response = {
      "document_name" => DOC_NAME,
      "aliases"       => ALIASES,
      "summary"       => "Descripción de la imagen.",
      "chunks"        => [ { "text" => "# S0", "page" => 1 } ]
    }.to_json

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        blocks = Array(params.dig(:messages)&.first&.dig(:content))
        captured_text_blocks.concat(
          blocks.select { |b| b.is_a?(Hash) && b[:type] == "text" }.map { |b| b[:text] }
        )
        content = [ OpenStruct.new(type: "text", text: golden_response) ]
        usage   = OpenStruct.new(input_tokens: 10, output_tokens: 20,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-opus-4-7")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    SingleFileChunkingService.new(
      binary: "\xFF\xD8 fake", content_type: "image/jpeg", filename: "photo.jpg",
      s3_key: "uploads/photo.jpg", sha256: Digest::SHA256.hexdigest("fake"),
      s3_service: @fake_s3, locale: "es"
    ).call

    assert(captured_text_blocks.any? { |t| t.include?("Summary language: es") },
           "expected a 'Summary language: es' text block in the Claude request")
  end

  test "image mode: summary populated on ChunkAsset when Claude returns it" do
    @response_json = {
      "document_name" => DOC_NAME,
      "aliases"       => ALIASES,
      "summary"       => "Imagen del cuadro de maniobras de un Schindler 5500.",
      "chunks"        => [ { "text" => "# S0", "page" => 1 } ]
    }.to_json

    asset = build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call

    assert_match(/Schindler 5500/, asset.summary)
  end

  test "pdf mode: summary remains nil (no locale block sent)" do
    asset = build_service.call  # default content_type application/pdf
    assert_nil asset.summary
  end

  test "image mode: companion_offer populated on ChunkAsset when Claude returns it" do
    @response_json = {
      "document_name"   => DOC_NAME,
      "aliases"         => ALIASES,
      "summary"         => "Parece el cuadro de un Schindler.",
      "companion_offer" => "Pregúntame lo que necesites, aunque sea con pocas palabras.",
      "chunks"          => [ { "text" => "# S0", "page" => 1 } ]
    }.to_json

    asset = build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call

    assert_match(/Pregúntame/, asset.companion_offer)
  end

  test "pdf mode: companion_offer remains nil" do
    asset = build_service.call
    assert_nil asset.companion_offer
  end
end
