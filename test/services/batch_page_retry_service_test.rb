# frozen_string_literal: true

require "test_helper"
require "ostruct"

class BatchPageRetryServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  VALID_JSON = JSON.generate(
    "document_name" => "Orona ARCA II Manual",
    "aliases"       => [ "ARCA II" ],
    "chunks"        => [ { "text" => "S0 content", "page" => 6, "field_records" => [] } ]
  )

  # B.3: literal quotes inside chunks[].text are recoverable without a paid retry.
  RECOVERABLE_QUOTED_JSON = '{"document_name":"Manual","chunks":[{"text":"Consulte la sección "Etiquetas"","page":6}]}'
  BROKEN_JSON = '{"document_name":"Manual","chunks":[{"text":"unterminated","page":6}'

  FakeUsage = Struct.new(:input_tokens, :output_tokens,
                          :cache_read_input_tokens, :cache_creation_input_tokens,
                          keyword_init: true)

  def make_usage(input: 100, output: 500)
    FakeUsage.new(input_tokens: input, output_tokens: output,
                  cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
  end

  # ── needs_retry? / parseable_json? ──────────────────────────────────────────

  test "parseable_json? accepts plain, fenced and recoverable quoted JSON, rejects broken JSON and nil" do
    assert BatchPageRetryService.parseable_json?(VALID_JSON)
    assert BatchPageRetryService.parseable_json?("```json\n#{VALID_JSON}\n```")
    assert BatchPageRetryService.parseable_json?(RECOVERABLE_QUOTED_JSON)
    assert_not BatchPageRetryService.parseable_json?(BROKEN_JSON)
    assert_not BatchPageRetryService.parseable_json?(nil)
    assert_not BatchPageRetryService.parseable_json?("")
  end

  test "needs_retry? on truncation and unrecoverable JSON, not on healthy or recoverable quoted pages" do
    assert BatchPageRetryService.needs_retry?({ text: VALID_JSON, stop_reason: "max_tokens" })
    assert BatchPageRetryService.needs_retry?({ text: BROKEN_JSON, stop_reason: "end_turn" }),
           "end_turn with unrecoverable JSON must trigger a retry"
    assert_not BatchPageRetryService.needs_retry?({ text: RECOVERABLE_QUOTED_JSON, stop_reason: "end_turn" })
    assert_not BatchPageRetryService.needs_retry?({ text: VALID_JSON, stop_reason: "end_turn" })
    assert_not BatchPageRetryService.needs_retry?({ text: VALID_JSON, stop_reason: nil })
  end

  # ── retry_failed_pages! ──────────────────────────────────────────────────────

  def with_retry_harness(client_results:, page_binaries: { 6 => "page-6-pdf" })
    fake_s3 = Object.new
    fake_s3.define_singleton_method(:get_object) { |**| OpenStruct.new(body: StringIO.new("pdf")) }

    fake_splitter = Object.new
    fake_splitter.define_singleton_method(:each_page) do |&block|
      page_binaries.each { |num, bin| block.call(num, bin) }
    end

    calls = []
    results = client_results
    fake_client = Object.new
    fake_client.define_singleton_method(:call) do |**kwargs|
      calls << kwargs
      result = results[calls.size - 1] || results.last
      raise result if result.is_a?(StandardError)
      result
    end

    original_s3       = Aws::S3::Client.method(:new)
    original_splitter = PdfPageSplitterService.method(:new)
    original_client   = ClaudeChunkingClient.method(:new)
    Aws::S3::Client.define_singleton_method(:new) { |*_, **_| fake_s3 }
    PdfPageSplitterService.define_singleton_method(:new) { |_| fake_splitter }
    ClaudeChunkingClient.define_singleton_method(:new) { |**_| fake_client }

    yield calls
  ensure
    Aws::S3::Client.define_singleton_method(:new, original_s3)
    PdfPageSplitterService.define_singleton_method(:new, original_splitter)
    ClaudeChunkingClient.define_singleton_method(:new, original_client)
  end

  def invalid_page(page: 6, model: "claude-sonnet-4-6")
    { page_number: page, text: BROKEN_JSON, model: model, stop_reason: "end_turn" }
  end

  test "retries an unrecoverable JSON end_turn page once when the retry parses" do
    pages  = [ invalid_page ]
    usages = []

    with_retry_harness(client_results: [ { text: VALID_JSON, usage: make_usage, stop_reason: nil } ]) do |calls|
      BatchPageRetryService.new.retry_failed_pages!(
        page_results: pages,
        s3_key:       "bulk_uploads/manual.pdf",
        filename:     "manual.pdf",
        sha256:       "a" * 64,
        on_usage:     ->(usage) { usages << usage }
      )

      assert_equal 1, calls.size, "one billable retry call"
      assert_equal BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS, calls.first[:max_tokens]
      assert_equal 2,            calls.first[:attempt]
      assert_equal "bulk_retry", calls.first[:route]
      assert_equal "bulk_retry", calls.first[:tracking_prefix]
      assert_equal "ingest:#{'a' * 12}:p6", calls.first[:correlation_id]
    end

    assert_equal VALID_JSON, pages.first[:text]
    assert_nil pages.first[:stop_reason]
    assert_equal 1, usages.size, "on_usage once per billed retry"
  end

  test "escalates to 32k when the 16k retry is still unparseable" do
    pages = [ invalid_page ]

    with_retry_harness(client_results: [
      { text: BROKEN_JSON, usage: make_usage, stop_reason: nil },
      { text: VALID_JSON,   usage: make_usage, stop_reason: nil }
    ]) do |calls|
      BatchPageRetryService.new.retry_failed_pages!(
        page_results: pages, s3_key: "k", filename: "manual.pdf", sha256: "b" * 64
      )

      assert_equal 2, calls.size
      assert_equal [ BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS, BatchChunkingPrompt::MAX_TOKENS ],
                   calls.pluck(:max_tokens)
      assert_equal [ 2, 3 ], calls.pluck(:attempt)
    end

    assert_equal VALID_JSON, pages.first[:text]
  end

  test "escalates on truncation even when the truncated output parses" do
    pages = [ { page_number: 6, text: VALID_JSON, model: "claude-sonnet-4-6", stop_reason: "max_tokens" } ]

    with_retry_harness(client_results: [
      { text: VALID_JSON, usage: make_usage, stop_reason: "max_tokens" },
      { text: VALID_JSON, usage: make_usage, stop_reason: nil }
    ]) do |calls|
      BatchPageRetryService.new.retry_failed_pages!(
        page_results: pages, s3_key: "k", filename: "manual.pdf", sha256: "c" * 64
      )
      assert_equal 2, calls.size, "max_tokens at 16k must escalate to 32k"
    end
  end

  test "leaves the page degraded after exhausting the ladder" do
    pages = [ invalid_page ]

    with_retry_harness(client_results: [
      { text: BROKEN_JSON, usage: make_usage, stop_reason: nil },
      { text: BROKEN_JSON, usage: make_usage, stop_reason: nil }
    ]) do |calls|
      BatchPageRetryService.new.retry_failed_pages!(
        page_results: pages, s3_key: "k", filename: "manual.pdf", sha256: "d" * 64
      )
      assert_equal 2, calls.size, "ladder is bounded at two direct rungs"
    end

    assert_equal BROKEN_JSON, pages.first[:text], "degraded page keeps the last attempt for the merger marker"
  end

  test "stops the page ladder on ApiError without raising" do
    pages = [ invalid_page ]

    with_retry_harness(client_results: [ ClaudeChunkingClient::ApiError.new("boom") ]) do |calls|
      assert_nothing_raised do
        BatchPageRetryService.new.retry_failed_pages!(
          page_results: pages, s3_key: "k", filename: "manual.pdf", sha256: "e" * 64
        )
      end
      assert_equal 1, calls.size
    end

    assert_equal BROKEN_JSON, pages.first[:text]
  end

  test "healthy pages trigger no S3 download and no client calls" do
    pages = [ { page_number: 1, text: VALID_JSON, model: "claude-sonnet-4-6", stop_reason: "end_turn" } ]

    original_s3 = Aws::S3::Client.method(:new)
    Aws::S3::Client.define_singleton_method(:new) { |*_, **_| flunk("S3 must not be touched") }

    result = BatchPageRetryService.new.retry_failed_pages!(
      page_results: pages, s3_key: "k", filename: "manual.pdf", sha256: "f" * 64
    )
    assert_same pages, result
  ensure
    Aws::S3::Client.define_singleton_method(:new, original_s3)
  end

  test "returns results unchanged when the S3 download fails" do
    pages = [ invalid_page ]

    original_s3 = Aws::S3::Client.method(:new)
    Aws::S3::Client.define_singleton_method(:new) { |*_, **_| raise "no credentials" }

    result = BatchPageRetryService.new.retry_failed_pages!(
      page_results: pages, s3_key: "k", filename: "manual.pdf", sha256: "0" * 64
    )

    assert_same pages, result
    assert_equal BROKEN_JSON, pages.first[:text]
  ensure
    Aws::S3::Client.define_singleton_method(:new, original_s3)
  end

  test "strips -batch suffix from the result model before building the retry client" do
    pages = [ invalid_page(model: "claude-opus-4-7-batch") ]
    captured_model = nil

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:get_object) { |**| OpenStruct.new(body: StringIO.new("pdf")) }
    fake_splitter = Object.new
    fake_splitter.define_singleton_method(:each_page) { |&block| block.call(6, "bin") }
    fake_client = Object.new
    fake_client.define_singleton_method(:call) { |**| { text: VALID_JSON, usage: nil, stop_reason: nil } }

    original_s3       = Aws::S3::Client.method(:new)
    original_splitter = PdfPageSplitterService.method(:new)
    original_client   = ClaudeChunkingClient.method(:new)
    Aws::S3::Client.define_singleton_method(:new) { |*_, **_| fake_s3 }
    PdfPageSplitterService.define_singleton_method(:new) { |_| fake_splitter }
    ClaudeChunkingClient.define_singleton_method(:new) do |model:, **|
      captured_model = model
      fake_client
    end

    BatchPageRetryService.new.retry_failed_pages!(
      page_results: pages, s3_key: "k", filename: "scan.pdf", sha256: "9" * 64
    )

    assert_equal "claude-opus-4-7", captured_model
  ensure
    Aws::S3::Client.define_singleton_method(:new, original_s3)
    PdfPageSplitterService.define_singleton_method(:new, original_splitter)
    ClaudeChunkingClient.define_singleton_method(:new, original_client)
  end
end
