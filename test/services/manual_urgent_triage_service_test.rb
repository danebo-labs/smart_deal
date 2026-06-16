# frozen_string_literal: true

require "test_helper"
require "ostruct"

class ManualUrgentTriageServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @orig_splitter_new = PdfPageSplitterService.method(:new)
  end

  teardown do
    PdfPageSplitterService.define_singleton_method(:new, @orig_splitter_new)
  end

  test "parses selected pages, writes manual_batch chunks, and enqueues partial Bedrock sync" do
    fake_splitter = Object.new
    fake_splitter.define_singleton_method(:page_count) { 8 }
    PdfPageSplitterService.define_singleton_method(:new) { |_binary| fake_splitter }

    selector = Object.new
    selector.define_singleton_method(:select) do |**|
      [
        ManualUrgentPageSelector::Page.new(number: 2, binary: "page 2", model: BatchChunkingPrompt::MODEL_TEXT),
        ManualUrgentPageSelector::Page.new(number: 5, binary: "page 5", model: BatchChunkingPrompt::MODEL_TEXT)
      ]
    end

    s3 = Object.new
    uploaded_keys = []
    s3.define_singleton_method(:delete_prefix) { |_prefix| 0 }
    s3.define_singleton_method(:upload_text) { |key, _content| uploaded_keys << key; key }

    bulk_sync = Object.new
    bulk_sync.define_singleton_method(:sync!) do |uploaded_filenames:, locale:|
      { job_id: "ingest-urgent", kb_id: "kb", data_source_id: "ds" }
    end

    bedrock_calls = []
    bedrock = Class.new do
      define_singleton_method(:perform_later) do |*args, **kwargs|
        bedrock_calls << [ args, kwargs ]
      end
    end

    json_builder = method(:page_json)
    client = Object.new
    client.define_singleton_method(:call) do |page_number:, **|
      {
        text: json_builder.call(page_number),
        usage: OpenStruct.new(input_tokens: 100, output_tokens: 50),
        model: BatchChunkingPrompt::MODEL_TEXT,
        stop_reason: nil
      }
    end

    result = ManualUrgentTriageService.new(
      selector: selector,
      s3_service: s3,
      bulk_sync_service: bulk_sync,
      bedrock_job: bedrock,
      client_factory: ->(_model) { client }
    ).call(
      binary: "%PDF",
      filename: "manual.pdf",
      sha256: Digest::SHA256.hexdigest("manual"),
      s3_key: "uploads/manual.pdf",
      query: "rescate emergencia",
      kb_doc_id: 123,
      conv_session_id: 456,
      locale: "es",
      web_manual_batch_id: 789
    )

    assert uploaded_keys.any? { |key| key.include?("bulk_chunks/") && key.end_with?(".txt") }
    assert_equal "urgent_pages", result["processing_scope"]
    assert_equal [ 2, 5 ], result["selected_pages"]
    assert_equal 8, result["total_pages"]

    assert_equal 1, bedrock_calls.size
    args, kwargs = bedrock_calls.first
    assert_equal "ingest-urgent", args.first
    assert_equal [ "manual.pdf" ], args.second
    assert_equal [ 123 ], kwargs[:kb_document_ids]
    metadata = kwargs[:web_v1_metadata].first
    assert_equal "urgent_pages", metadata["processing_scope"]
    assert_equal [ 2, 5 ], metadata["selected_pages"]
    assert_equal 789, metadata["web_manual_batch_id"]
  end

  test "multi selected pages: first page ANCHOR_PAGE, rest CONTENT_PAGE" do
    roles = run_triage_capturing_roles(
      [
        ManualUrgentPageSelector::Page.new(number: 2, binary: "page 2", model: BatchChunkingPrompt::MODEL_TEXT),
        ManualUrgentPageSelector::Page.new(number: 5, binary: "page 5", model: BatchChunkingPrompt::MODEL_TEXT)
      ]
    )

    assert_includes roles[2], "Page role: ANCHOR_PAGE"
    assert_includes roles[5], "Page role: CONTENT_PAGE"
  end

  test "single selected page: page is ANCHOR_PAGE" do
    roles = run_triage_capturing_roles(
      [ ManualUrgentPageSelector::Page.new(number: 3, binary: "page 3", model: BatchChunkingPrompt::MODEL_TEXT) ]
    )

    assert_includes roles[3], "Page role: ANCHOR_PAGE"
  end

  test "raises NoPagesSelected before paid calls when selector returns none" do
    selector = Object.new
    selector.define_singleton_method(:select) { |**| [] }
    paid_called = false

    service = ManualUrgentTriageService.new(
      selector: selector,
      client_factory: ->(_model) { paid_called = true }
    )

    assert_raises ManualUrgentTriageService::NoPagesSelected do
      service.call(
        binary: "%PDF",
        filename: "manual.pdf",
        sha256: Digest::SHA256.hexdigest("manual"),
        s3_key: "uploads/manual.pdf",
        query: "rescate"
      )
    end
    assert_not paid_called
  end

  private

  # Drives the service end-to-end with all I/O stubbed, returning
  # { page_number => instruction_text } captured from each per-page Claude call.
  def run_triage_capturing_roles(selected_pages)
    fake_splitter = Object.new
    fake_splitter.define_singleton_method(:page_count) { 8 }
    PdfPageSplitterService.define_singleton_method(:new) { |_binary| fake_splitter }

    selector = Object.new
    selector.define_singleton_method(:select) { |**| selected_pages }

    s3 = Object.new
    s3.define_singleton_method(:delete_prefix) { |_prefix| 0 }
    s3.define_singleton_method(:upload_text) { |key, _content| key }

    bulk_sync = Object.new
    bulk_sync.define_singleton_method(:sync!) { |**| { job_id: "j", kb_id: "kb", data_source_id: "ds" } }

    bedrock = Class.new { define_singleton_method(:perform_later) { |*, **| nil } }

    roles = {}
    json_builder = method(:page_json)
    client = Object.new
    client.define_singleton_method(:call) do |page_number:, user_content:, **|
      roles[page_number] = user_content.last[:text]
      {
        text: json_builder.call(page_number),
        usage: OpenStruct.new(input_tokens: 100, output_tokens: 50),
        model: BatchChunkingPrompt::MODEL_TEXT,
        stop_reason: nil
      }
    end

    ManualUrgentTriageService.new(
      selector: selector,
      s3_service: s3,
      bulk_sync_service: bulk_sync,
      bedrock_job: bedrock,
      client_factory: ->(_model) { client }
    ).call(
      binary: "%PDF",
      filename: "manual.pdf",
      sha256: Digest::SHA256.hexdigest("manual"),
      s3_key: "uploads/manual.pdf",
      query: "rescate emergencia",
      locale: "es"
    )

    roles
  end

  def page_json(page_number)
    JSON.generate(
      "document_name" => "Manual Rescue",
      "aliases" => [ "rescue" ],
      "summary" => "Parece un manual con instrucciones de rescate.",
      "companion_offer" => "Dime qué necesitas saber sobre este manual.",
      "chunks" => [
        {
          "text" => "## Rescue page #{page_number}\nUse documented rescue procedure.",
          "page" => page_number,
          "aliases" => [ "rescue" ],
          "field_records" => []
        }
      ]
    )
  end
end
