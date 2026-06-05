# frozen_string_literal: true

require "test_helper"
require "ostruct"

class SingleFileChunkingServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Shared fixtures
  # ---------------------------------------------------------------------------

  DOC_NAME   = "Orona Hydraulic Manual"
  ALIASES    = %w[HPM-400 orona hydraulic]
  PHOTO_NAME = "Door Operator Motor"

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

  # FieldPhotoPrompt-compatible JSON (for image/* paths)
  def field_photo_json(summary: nil, companion_offer: nil)
    base = {
      "canonical_component"      => PHOTO_NAME,
      "manufacturer"             => "Schindler",
      "model"                    => "5500",
      "subsystem"                => "DOOR_OPERATOR",
      "condition"                => "GOOD",
      "aliases"                  => ALIASES,
      "anti_hallucination_notes" => "Manufacturer visible on label."
    }
    base["summary"] = summary if summary
    base.to_json
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

  test "image/jpeg: writes chunks via field_photo_v1 path" do
    @response_json = field_photo_json
    asset = build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call
    assert_equal PHOTO_NAME, asset.canonical_name
  end

  test "image/jpeg: sidecar ingestion_path is field_photo_v1" do
    @response_json = field_photo_json
    build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call
    sidecar_key = @fake_s3.uploads.keys.find { |k| k.end_with?(".metadata.json") }
    assert_not_nil sidecar_key
    attrs = JSON.parse(@fake_s3.uploads[sidecar_key])["metadataAttributes"]
    assert_equal "field_photo_v1", attrs["ingestion_path"]
  end

  test "image/jpeg: uses Sonnet model (FieldPhotoDensityGate default)" do
    captured_models = []
    photo_response  = field_photo_json

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        captured_models << params[:model]
        content = [ OpenStruct.new(type: "text", text: photo_response) ]
        usage   = OpenStruct.new(input_tokens: 10, output_tokens: 20,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: params[:model])
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call

    assert captured_models.all? { |m| m == BatchChunkingPrompt::MODEL_TEXT },
           "expected Sonnet (MODEL_TEXT) for all image calls, got: #{captured_models.inspect}"
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

  test "pptx office extension triggers OfficeToPdfConverter before routing" do
    orig_convert = OfficeToPdfConverter.method(:convert)
    converted = false
    OfficeToPdfConverter.define_singleton_method(:convert) do |_, **|
      converted = true
      "%PDF-1.4 fake"
    end

    asset = build_service(
      filename:     "deck.pptx",
      content_type: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      binary:       "PK fake"
    ).call
    assert converted, "expected OfficeToPdfConverter.convert to be called for pptx"
    assert_equal DOC_NAME, asset.canonical_name
  ensure
    OfficeToPdfConverter.define_singleton_method(:convert, orig_convert)
  end

  test "office handle_office falls back to pdf_text_only when router returns unknown mode" do
    # Simulates the case where FileMultimodalRouter classifies the converted PDF
    # with a mode other than :pdf_mixed / :pdf_text_only (e.g. :text).
    # Before the fix this called handle_text_binary(pdf_binary) which blew up with
    # JSON::GeneratorError when the PDF bytes were serialised as UTF-8 text.
    orig_convert = OfficeToPdfConverter.method(:convert)
    OfficeToPdfConverter.define_singleton_method(:convert) { |_, **| "%PDF-1.4 fake" }

    orig_classify = FileMultimodalRouter.method(:classify)
    FileMultimodalRouter.define_singleton_method(:classify) do |**|
      FileMultimodalRouter::Result.new(model: BatchChunkingPrompt::MODEL_TEXT, mode: :text, pages: [])
    end

    # Should not raise — previously raised JSON::GeneratorError
    asset = assert_nothing_raised do
      build_service(filename: "slides.pptx", content_type: "application/vnd.openxmlformats-officedocument.presentationml.presentation", binary: "PK fake").call
    end
    assert_equal DOC_NAME, asset.canonical_name
  ensure
    OfficeToPdfConverter.define_singleton_method(:convert, orig_convert)
    FileMultimodalRouter.define_singleton_method(:classify, orig_classify)
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

    orig_filter = PageRelevanceFilter.method(:filter_pages)
    PageRelevanceFilter.define_singleton_method(:filter_pages) do |pages:, **|
      pages.each_with_object({}) do |page, h|
        h[page.number] = { keep: true, reason: :test, source: :stub, force_opus: false }
      end
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
    PageRelevanceFilter.define_singleton_method(:filter_pages, orig_filter)
  end

  # ─── Image summary + locale ──────────────────────────────────────────────────

  test "image mode: locale is forwarded as 'Summary language' text-block" do
    captured_text_blocks = []
    photo_response       = field_photo_json(summary: "Descripción de la imagen.")

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        blocks = Array(params.dig(:messages)&.first&.dig(:content))
        captured_text_blocks.concat(
          blocks.select { |b| b.is_a?(Hash) && b[:type] == "text" }.map { |b| b[:text] }
        )
        content = [ OpenStruct.new(type: "text", text: photo_response) ]
        usage   = OpenStruct.new(input_tokens: 10, output_tokens: 20,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6")
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
    @response_json = field_photo_json(summary: "Imagen del cuadro de maniobras de un Schindler 5500.")

    asset = build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call

    assert_match(/Schindler 5500/, asset.summary)
  end

  test "pdf mode: summary is nil when Claude response omits it (still emitted by prompt)" do
    # golden_json fixture has no summary field — asset.summary reflects what Claude returns.
    asset = build_service.call  # default content_type application/pdf
    assert_nil asset.summary
  end

  test "image mode: companion_offer is nil (field_photo_v1 schema has no companion_offer)" do
    @response_json = field_photo_json(summary: "Parece el cuadro de un Schindler.")

    asset = build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call

    assert_nil asset.companion_offer
  end

  test "pdf mode: companion_offer is nil when Claude response omits it" do
    asset = build_service.call
    assert_nil asset.companion_offer
  end

  # ─── locale forwarding for non-image types ───────────────────────────────────

  test "text mode: locale is forwarded as 'Summary language' text block" do
    captured_text_blocks = []
    self_ref             = self

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        blocks = Array(params.dig(:messages)&.first&.dig(:content))
        captured_text_blocks.concat(
          blocks.select { |b| b.is_a?(Hash) && b[:type] == "text" }.map { |b| b[:text] }
        )
        content = [ OpenStruct.new(type: "text", text: self_ref.instance_variable_get(:@response_json)) ]
        usage   = OpenStruct.new(input_tokens: 10, output_tokens: 20,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    SingleFileChunkingService.new(
      binary: "hello world", content_type: "text/plain", filename: "note.txt",
      s3_key: "uploads/note.txt", sha256: Digest::SHA256.hexdigest("hello world"),
      s3_service: @fake_s3, locale: "en"
    ).call

    assert(captured_text_blocks.any? { |t| t.include?("Summary language: en") },
           "expected 'Summary language: en' text block in Claude request for text mode")
  end

  test "pdf_text_only mode: locale is forwarded as 'Summary language' hint" do
    captured_text_blocks = []
    self_ref             = self

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        blocks = Array(params.dig(:messages)&.first&.dig(:content))
        captured_text_blocks.concat(
          blocks.select { |b| b.is_a?(Hash) && b[:type] == "text" }.map { |b| b[:text] }
        )
        content = [ OpenStruct.new(type: "text", text: self_ref.instance_variable_get(:@response_json)) ]
        usage   = OpenStruct.new(input_tokens: 10, output_tokens: 20,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    SingleFileChunkingService.new(
      binary: "%PDF-1.4", content_type: "application/pdf", filename: "manual.pdf",
      s3_key: "uploads/manual.pdf", sha256: Digest::SHA256.hexdigest("%PDF-1.4"),
      s3_service: @fake_s3, locale: "es"
    ).call

    assert(captured_text_blocks.any? { |t| t.include?("Summary language: es") },
           "expected 'Summary language: es' text block in Claude request for pdf_text_only mode")
  end

  # ─── office_origin → call_batch routing ──────────────────────────────────────

  BPRFakePdfPage = Struct.new(:number, :binary, :model, :force_opus) unless defined?(BPRFakePdfPage)

  test "pptx handle_office sets office_origin and pdf_mixed uses call_batch" do
    pages = (1..4).map { |n| BPRFakePdfPage.new(n, "%PDF-fake-p#{n}", BatchChunkingPrompt::MODEL_MULTIMODAL, false) }

    orig_convert  = OfficeToPdfConverter.method(:convert)
    orig_classify = FileMultimodalRouter.method(:classify)
    orig_call_batch = PageRelevanceFilter.method(:call_batch)
    orig_prf_new    = PageRelevanceFilter.method(:new)

    OfficeToPdfConverter.define_singleton_method(:convert) { |_, **| "%PDF-1.4 fake" }

    # First classify call (original binary, pptx content-type) → :office
    # Second classify call (converted PDF binary) → :pdf_mixed with pages
    classify_call_count = 0
    FileMultimodalRouter.define_singleton_method(:classify) do |**|
      classify_call_count += 1
      if classify_call_count == 1
        OpenStruct.new(mode: :office, pages: [])
      else
        OpenStruct.new(mode: :pdf_mixed, pages: pages)
      end
    end

    call_batch_invoked = false
    prf_new_invoked    = false

    PageRelevanceFilter.define_singleton_method(:call_batch) do |**_kwargs|
      call_batch_invoked = true
      # Drop p1/p2, keep p3/p4
      {
        1 => { keep: false, reason: :cover,   source: :haiku_batch, force_opus: false },
        2 => { keep: false, reason: :agenda,  source: :haiku_batch, force_opus: false },
        3 => { keep: true,  reason: :diagram, source: :haiku_batch, force_opus: true  },
        4 => { keep: true,  reason: :schema,  source: :haiku_batch, force_opus: true  }
      }
    end

    PageRelevanceFilter.define_singleton_method(:new) do |*|
      prf_new_invoked = true
      OpenStruct.new(call: { keep: true, reason: "stub", source: "stub" })
    end

    # Track which page numbers reach Claude (stream calls)
    claude_page_numbers = []
    response_text       = golden_json
    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        text_blocks = Array(params.dig(:messages)&.find { |m| m[:role] == "user" }&.dig(:content))
                        .select { |b| b.is_a?(Hash) && b[:type] == "text" }
                        .map { |b| b[:text] }
                        .join(" ")
        if (m = text_blocks.match(/Page (\d+) of/))
          claude_page_numbers << m[1].to_i
        end
        content = [ OpenStruct.new(type: "text", text: response_text) ]
        usage   = OpenStruct.new(input_tokens: 100, output_tokens: 200,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-opus-4-7")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    build_service(filename: "deck.pptx",
                  content_type: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                  binary: "PK fake").call

    assert call_batch_invoked, "expected call_batch to be used for office origin"
    assert_not prf_new_invoked, "expected per-page PageRelevanceFilter.new NOT to be used for office origin"
    assert_not_includes claude_page_numbers, 1, "p1 (cover) must not reach Claude"
    assert_not_includes claude_page_numbers, 2, "p2 (agenda) must not reach Claude"
  ensure
    OfficeToPdfConverter.define_singleton_method(:convert, orig_convert)
    FileMultimodalRouter.define_singleton_method(:classify, orig_classify)
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_call_batch)
    PageRelevanceFilter.define_singleton_method(:new, orig_prf_new)
  end

  test "native PDF pdf_mixed with 2 pages uses call_batch, not per-page" do
    pages = (1..2).map { |n| BPRFakePdfPage.new(n, "%PDF-fake-p#{n}", BatchChunkingPrompt::MODEL_MULTIMODAL, false) }

    orig_classify   = FileMultimodalRouter.method(:classify)
    orig_call_batch = PageRelevanceFilter.method(:call_batch)
    orig_prf_new    = PageRelevanceFilter.method(:new)

    FileMultimodalRouter.define_singleton_method(:classify) do |**|
      OpenStruct.new(mode: :pdf_mixed, pages: pages)
    end

    call_batch_invoked = false
    prf_new_invoked    = false

    PageRelevanceFilter.define_singleton_method(:call_batch) do |**|
      call_batch_invoked = true
      { 1 => { keep: true, reason: :content, source: :haiku_batch, force_opus: false },
        2 => { keep: true, reason: :content, source: :haiku_batch, force_opus: false } }
    end

    PageRelevanceFilter.define_singleton_method(:new) do |*|
      prf_new_invoked = true
      OpenStruct.new(call: { keep: true, reason: "content", source: :heuristic })
    end

    build_service(filename: "manual.pdf").call

    assert call_batch_invoked,   "native PDF 2p must use call_batch (filter_pages routing)"
    assert_not prf_new_invoked,  "native PDF 2p must NOT use per-page PageRelevanceFilter.new"
  ensure
    FileMultimodalRouter.define_singleton_method(:classify, orig_classify)
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_call_batch)
    PageRelevanceFilter.define_singleton_method(:new, orig_prf_new)
  end

  # ─── cap + retry (WEB_PAGE_MAX_TOKENS) ────────────────────────────────────────

  RetryFakePdfPage = Struct.new(:number, :binary, :model, :force_opus) unless defined?(RetryFakePdfPage)

  # Helper that builds a streaming fake where each successive call consumes the next response.
  def build_sequential_anthropic_client(responses)
    call_idx = 0
    mutex    = Mutex.new
    msgs = Object.new
    msgs.define_singleton_method(:stream) do |params|
      idx = mutex.synchronize { call_idx.tap { call_idx += 1 } }
      resp_text, stop = responses[idx] || responses.last
      content = [ OpenStruct.new(type: "text", text: resp_text) ]
      usage   = OpenStruct.new(input_tokens: 50, output_tokens: 80,
                               cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
      message = OpenStruct.new(content: content, usage: usage, model: "claude-opus-4-7",
                               stop_reason: stop)
      OpenStruct.new(accumulated_message: message, last_params: params)
    end
    msgs.define_singleton_method(:last_params) { nil }

    client = OpenStruct.new(messages: msgs, api_key: "fake")
    client
  end

  test "pdf_mixed: retries with WEB_PAGE_RETRY_MAX_TOKENS when first call is truncated (Opus)" do
    page1 = RetryFakePdfPage.new(1, "%PDF-fake-p1", BatchChunkingPrompt::MODEL_MULTIMODAL, false)

    orig_classify = FileMultimodalRouter.method(:classify)
    orig_prf_new  = PageRelevanceFilter.method(:new)

    FileMultimodalRouter.define_singleton_method(:classify) do |**|
      OpenStruct.new(mode: :pdf_mixed, pages: [ page1 ])
    end
    PageRelevanceFilter.define_singleton_method(:new) do |*|
      OpenStruct.new(call: { keep: true, reason: "content", source: :heuristic })
    end

    response_json = golden_json
    captured_max_tokens = []

    Anthropic::Client.define_singleton_method(:new) do |**|
      call_idx = 0
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        captured_max_tokens << params[:max_tokens]
        stop   = call_idx == 0 ? "max_tokens" : "end_turn"
        text   = response_json
        call_idx += 1
        content = [ OpenStruct.new(type: "text", text: text) ]
        usage   = OpenStruct.new(input_tokens: 50, output_tokens: 80,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-opus-4-7",
                                 stop_reason: stop)
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    build_service(filename: "manual.pdf").call

    assert_equal 2, captured_max_tokens.size, "expected exactly 2 Claude calls (first + retry)"
    assert_equal BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,       captured_max_tokens[0]
    assert_equal BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS, captured_max_tokens[1]
  ensure
    FileMultimodalRouter.define_singleton_method(:classify, orig_classify)
    PageRelevanceFilter.define_singleton_method(:new, orig_prf_new)
  end

  test "pdf_mixed: no retry when first call succeeds (end_turn), uses WEB_PAGE_MAX_TOKENS only" do
    page1 = RetryFakePdfPage.new(1, "%PDF-fake-p1", BatchChunkingPrompt::MODEL_TEXT, false)

    orig_classify = FileMultimodalRouter.method(:classify)
    orig_prf_new  = PageRelevanceFilter.method(:new)

    FileMultimodalRouter.define_singleton_method(:classify) do |**|
      OpenStruct.new(mode: :pdf_mixed, pages: [ page1 ])
    end
    PageRelevanceFilter.define_singleton_method(:new) do |*|
      OpenStruct.new(call: { keep: true, reason: "content", source: :heuristic })
    end

    captured_max_tokens = []
    response_text = golden_json

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        captured_max_tokens << params[:max_tokens]
        content = [ OpenStruct.new(type: "text", text: response_text) ]
        usage   = OpenStruct.new(input_tokens: 50, output_tokens: 80,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6",
                                 stop_reason: "end_turn")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    build_service(filename: "manual.pdf").call

    assert_equal 1, captured_max_tokens.size, "expected exactly 1 Claude call when not truncated"
    assert_equal BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS, captured_max_tokens[0]
  ensure
    FileMultimodalRouter.define_singleton_method(:classify, orig_classify)
    PageRelevanceFilter.define_singleton_method(:new, orig_prf_new)
  end

  test "handle_image: retries with WEB_PAGE_RETRY_MAX_TOKENS on truncation, succeeds on retry" do
    captured_max_tokens = []
    response_text       = field_photo_json

    Anthropic::Client.define_singleton_method(:new) do |**|
      call_idx = 0
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        captured_max_tokens << params[:max_tokens]
        stop  = call_idx == 0 ? "max_tokens" : "end_turn"
        call_idx += 1
        content = [ OpenStruct.new(type: "text", text: response_text) ]
        usage   = OpenStruct.new(input_tokens: 50, output_tokens: 80,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6",
                                 stop_reason: stop)
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    asset = build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call

    assert_equal 2, captured_max_tokens.size, "expected 2 calls: initial + retry"
    assert_equal BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,       captured_max_tokens[0]
    assert_equal BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS, captured_max_tokens[1]
    assert_equal PHOTO_NAME, asset.canonical_name
  end

  test "handle_image: no retry when first call succeeds, uses WEB_PAGE_MAX_TOKENS" do
    captured_max_tokens = []
    response_text       = field_photo_json

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        captured_max_tokens << params[:max_tokens]
        content = [ OpenStruct.new(type: "text", text: response_text) ]
        usage   = OpenStruct.new(input_tokens: 50, output_tokens: 80,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6",
                                 stop_reason: "end_turn")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    build_service(filename: "photo.jpg", content_type: "image/jpeg", binary: "\xFF\xD8 fake").call

    assert_equal 1, captured_max_tokens.size
    assert_equal BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS, captured_max_tokens[0]
  end

  test "pdf_text_only path uses MAX_TOKENS (no cap), not WEB_PAGE_MAX_TOKENS" do
    captured_max_tokens = []
    response_text = golden_json

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        captured_max_tokens << params[:max_tokens]
        content = [ OpenStruct.new(type: "text", text: response_text) ]
        usage   = OpenStruct.new(input_tokens: 50, output_tokens: 80,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6",
                                 stop_reason: "end_turn")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    build_service(filename: "manual.pdf", content_type: "application/pdf", binary: "%PDF-1.4").call

    assert_equal 1, captured_max_tokens.size
    assert_equal BatchChunkingPrompt::MAX_TOKENS, captured_max_tokens[0]
  end

  test "handle_text path uses MAX_TOKENS (no cap), not WEB_PAGE_MAX_TOKENS" do
    captured_max_tokens = []
    response_text = golden_json

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        captured_max_tokens << params[:max_tokens]
        content = [ OpenStruct.new(type: "text", text: response_text) ]
        usage   = OpenStruct.new(input_tokens: 50, output_tokens: 80,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6",
                                 stop_reason: "end_turn")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    build_service(filename: "note.txt", content_type: "text/plain", binary: "hello world").call

    assert_equal 1, captured_max_tokens.size
    assert_equal BatchChunkingPrompt::MAX_TOKENS, captured_max_tokens[0]
  end

  # ─── handle_pdf_mixed: fallback when all pages filtered ──────────────────────

  test "handle_pdf_mixed: falls back to whole-file when all pages filtered" do
    pages = (1..2).map { |n| BPRFakePdfPage.new(n, "%PDF-fake-p#{n}", BatchChunkingPrompt::MODEL_MULTIMODAL, false) }

    orig_classify = FileMultimodalRouter.method(:classify)
    orig_filter   = PageRelevanceFilter.method(:filter_pages)

    FileMultimodalRouter.define_singleton_method(:classify) do |**|
      OpenStruct.new(mode: :pdf_mixed, pages: pages)
    end

    # Simulate all pages being filtered out
    PageRelevanceFilter.define_singleton_method(:filter_pages) do |**|
      {
        1 => { keep: false, reason: :cover, source: :heuristic },
        2 => { keep: false, reason: :blank, source: :heuristic }
      }
    end

    claude_call_count = 0
    response_text     = golden_json

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        claude_call_count += 1
        content = [ OpenStruct.new(type: "text", text: response_text) ]
        usage   = OpenStruct.new(input_tokens: 50, output_tokens: 80,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6",
                                 stop_reason: "end_turn")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    asset = build_service(filename: "manual.pdf").call

    assert_equal 1, claude_call_count, "expected 1 whole-file call after all pages filtered"
    assert_equal DOC_NAME, asset.canonical_name, "expected asset to be populated via fallback"
    assert_not_nil asset.chunks_count
  ensure
    FileMultimodalRouter.define_singleton_method(:classify, orig_classify)
    PageRelevanceFilter.define_singleton_method(:filter_pages, orig_filter)
  end

  test "handle_pdf_mixed: large all-filtered PDF falls back to per-page keep-all" do
    pages = (1..(PageRelevanceFilter::BATCH_WINDOW_SIZE + 1)).map do |n|
      BPRFakePdfPage.new(n, "%PDF-fake-p#{n}", BatchChunkingPrompt::MODEL_TEXT, false)
    end

    orig_classify = FileMultimodalRouter.method(:classify)
    orig_filter   = PageRelevanceFilter.method(:filter_pages)

    FileMultimodalRouter.define_singleton_method(:classify) do |**|
      OpenStruct.new(mode: :pdf_mixed, pages: pages)
    end

    PageRelevanceFilter.define_singleton_method(:filter_pages) do |**|
      pages.each_with_object({}) do |page, h|
        h[page.number] = { keep: false, reason: :blank, source: :haiku_batch }
      end
    end

    mutex = Mutex.new
    captured_texts = []
    response_text  = golden_json

    Anthropic::Client.define_singleton_method(:new) do |**|
      msgs = Object.new
      msgs.define_singleton_method(:stream) do |params|
        text_blocks = Array(params.dig(:messages)&.find { |m| m[:role] == "user" }&.dig(:content))
                        .select { |b| b.is_a?(Hash) && b[:type] == "text" }
                        .map { |b| b[:text] }
                        .join(" ")
        mutex.synchronize { captured_texts << text_blocks }
        content = [ OpenStruct.new(type: "text", text: response_text) ]
        usage   = OpenStruct.new(input_tokens: 50, output_tokens: 80,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
        message = OpenStruct.new(content: content, usage: usage, model: "claude-sonnet-4-6",
                                 stop_reason: "end_turn")
        OpenStruct.new(accumulated_message: message)
      end
      OpenStruct.new(messages: msgs, api_key: "fake")
    end

    asset = build_service(filename: "large-manual.pdf").call

    assert_equal pages.size, captured_texts.size
    assert captured_texts.all? { |text| text.match?(/Page \d+ of #{pages.size}/) },
           "expected every fallback Claude call to be page-scoped"
    assert_equal DOC_NAME, asset.canonical_name
  ensure
    FileMultimodalRouter.define_singleton_method(:classify, orig_classify)
    PageRelevanceFilter.define_singleton_method(:filter_pages, orig_filter)
  end
end
