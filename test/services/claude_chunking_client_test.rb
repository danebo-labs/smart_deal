# frozen_string_literal: true

require "test_helper"
require "ostruct"

class ClaudeChunkingClientTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Fakes
  # ---------------------------------------------------------------------------

  class FakeUsage
    attr_reader :input_tokens, :output_tokens, :cache_read_input_tokens, :cache_creation_input_tokens

    def initialize(input: 10, output: 20, cache_read: 0, cache_creation: 0)
      @input_tokens               = input
      @output_tokens              = output
      @cache_read_input_tokens    = cache_read
      @cache_creation_input_tokens = cache_creation
    end

    def respond_to?(method, *) = [ :cache_read_input_tokens, :cache_creation_input_tokens ].include?(method) || super
  end

  class FakeContent
    attr_reader :type, :text

    def initialize(type:, text:)
      @type = type
      @text = text
    end
  end

  class FakeResponse
    attr_reader :content, :usage, :model

    def initialize(text:, model: BatchChunkingPrompt::MODEL_MULTIMODAL, usage: FakeUsage.new)
      @content = [ FakeContent.new(type: "text", text: text) ]
      @usage   = usage
      @model   = model
    end
  end

  class FakeStream
    def initialize(response:)
      @response = response
    end

    def accumulated_message
      @response
    end
  end

  class FakeMessages
    attr_reader :last_params

    def initialize(response:)
      @response = response
    end

    def stream(params)
      @last_params = params
      FakeStream.new(response: @response)
    end
  end

  class FakeAnthropicClient
    attr_reader :messages

    def initialize(response:)
      @messages = FakeMessages.new(response: response)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  GOLDEN_JSON = <<~JSON.strip
    {"document_name":"Pump Manual","aliases":["HPM-400"],"chunks":[{"text":"**Document: Pump Manual**\\n**DOCUMENT_ALIASES:**\\n- HPM-400\\n\\n# S0 — DOCUMENT IDENTIFICATION\\n| Field | Value |\\n|-|-|\\n| ORIGINAL_FILE_NAME | PIPELINE_INJECTED |","page":1}]}
  JSON

  def make_client(text: GOLDEN_JSON, model: BatchChunkingPrompt::MODEL_MULTIMODAL, usage: FakeUsage.new)
    response = FakeResponse.new(text: text, model: model, usage: usage)
    fake     = FakeAnthropicClient.new(response: response)
    ClaudeChunkingClient.new(model: model, client: fake)
  end

  # ---------------------------------------------------------------------------
  # call — basic behavior
  # ---------------------------------------------------------------------------

  test "returns text and usage from Anthropic response" do
    client = make_client
    result = client.call(user_content: [ { type: "text", text: "doc" } ], filename: "test.pdf")

    assert_equal GOLDEN_JSON, result[:text]
    assert_respond_to result[:usage], :input_tokens
  end

  test "passes system blocks and model to Anthropic" do
    client = make_client
    client.call(user_content: [ { type: "text", text: "doc" } ], filename: "test.pdf")

    last = client.instance_variable_get(:@client).messages.last_params
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, last[:model]
    assert_equal BatchChunkingPrompt::SYSTEM_BLOCKS,   last[:system]
    assert_equal BatchChunkingPrompt::MAX_TOKENS,      last[:max_tokens]
  end

  test "raises ApiError when Anthropic raises Anthropic::Errors::APIError" do
    fake_client = FakeAnthropicClient.new(response: nil)
    err_class = Class.new(Anthropic::Errors::APIError) do
      def initialize = super(url: "https://api.anthropic.com/v1/messages", status: 429, body: {})
    end
    fake_client.messages.define_singleton_method(:stream) { |_| raise err_class }

    client = ClaudeChunkingClient.new(model: "claude-opus-4-7", client: fake_client)

    assert_raises(ClaudeChunkingClient::ApiError) do
      client.call(user_content: [], filename: "x.pdf")
    end
  end

  test "raises ApiError when SDK raises ArgumentError (e.g. invalid params)" do
    fake_client = FakeAnthropicClient.new(response: nil)
    fake_client.messages.define_singleton_method(:stream) { |_| raise ArgumentError, "bad params" }

    client = ClaudeChunkingClient.new(model: "claude-opus-4-7", client: fake_client)

    assert_raises(ClaudeChunkingClient::ApiError) do
      client.call(user_content: [], filename: "x.pdf")
    end
  end

  # ---------------------------------------------------------------------------
  # Metrics tracking via TrackBedrockQueryJob
  # ---------------------------------------------------------------------------

  test "enqueues TrackBedrockQueryJob with -direct model suffix" do
    client  = make_client(model: "claude-sonnet-4-6")

    assert_enqueued_with(job: TrackBedrockQueryJob) do
      client.call(user_content: [], filename: "manual.pdf")
    end

    job_args = enqueued_jobs.last[:args].first
    assert_equal "claude-sonnet-4-6-direct", job_args["model_id"]
    assert_equal "web_parse: manual.pdf",     job_args["user_query"]
    assert_equal "ingestion_parse",           job_args["source"]
  end

  test "user_query includes page info for page-level calls" do
    client = make_client

    assert_enqueued_with(job: TrackBedrockQueryJob) do
      client.call(user_content: [], filename: "big.pdf", page_number: 3, total_pages: 10)
    end

    job_args = enqueued_jobs.last[:args].first
    assert_equal "web_parse: big.pdf p3/10", job_args["user_query"]
  end

  test "user_query accepts a custom tracking prefix" do
    client = make_client

    assert_enqueued_with(job: TrackBedrockQueryJob) do
      client.call(
        user_content: [],
        filename: "big.pdf",
        page_number: 3,
        total_pages: 10,
        tracking_prefix: "bulk_retry"
      )
    end

    job_args = enqueued_jobs.last[:args].first
    assert_equal "bulk_retry: big.pdf p3/10", job_args["user_query"]
  end

  test "cache_read_tokens included when usage reports non-zero" do
    usage  = FakeUsage.new(input: 5, output: 10, cache_read: 500, cache_creation: 0)
    client = make_client(usage: usage)

    assert_enqueued_with(job: TrackBedrockQueryJob) do
      client.call(user_content: [], filename: "doc.pdf")
    end

    job_args = enqueued_jobs.last[:args].first
    assert_equal 500, job_args["cache_read_tokens"]
    assert_nil        job_args["cache_creation_tokens"]
  end

  # ---------------------------------------------------------------------------
  # max_tokens parameter + stop_reason
  # ---------------------------------------------------------------------------

  test "passes MAX_TOKENS by default when max_tokens not specified" do
    client = make_client
    client.call(user_content: [ { type: "text", text: "doc" } ], filename: "test.pdf")

    last = client.instance_variable_get(:@client).messages.last_params
    assert_equal BatchChunkingPrompt::MAX_TOKENS, last[:max_tokens]
  end

  test "passes custom max_tokens value to Anthropic stream call" do
    client = make_client
    client.call(
      user_content: [ { type: "text", text: "doc" } ],
      filename:     "test.pdf",
      max_tokens:   BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS
    )

    last = client.instance_variable_get(:@client).messages.last_params
    assert_equal BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS, last[:max_tokens]
  end

  test "stop_reason is nil when response does not report max_tokens" do
    client = make_client
    result = client.call(user_content: [ { type: "text", text: "doc" } ], filename: "test.pdf")

    assert_nil result[:stop_reason]
  end

  test "stop_reason is 'max_tokens' when response reports truncation" do
    response = FakeResponse.new(text: GOLDEN_JSON)
    response.define_singleton_method(:stop_reason) { "max_tokens" }

    fake = FakeAnthropicClient.new(response: response)
    client = ClaudeChunkingClient.new(model: "claude-opus-4-7", client: fake)

    result = client.call(user_content: [], filename: "big.pdf")
    assert_equal "max_tokens", result[:stop_reason]
  end

  test "stop_reason is nil when response reports end_turn" do
    response = FakeResponse.new(text: GOLDEN_JSON)
    response.define_singleton_method(:stop_reason) { "end_turn" }

    fake = FakeAnthropicClient.new(response: response)
    client = ClaudeChunkingClient.new(model: "claude-opus-4-7", client: fake)

    result = client.call(user_content: [], filename: "ok.pdf")
    assert_nil result[:stop_reason]
  end

  # ---------------------------------------------------------------------------
  # Gate 9R I0 telemetry
  # ---------------------------------------------------------------------------

  test "tracks max_tokens, raw stop_reason, attempt, correlation_id and route" do
    response = FakeResponse.new(text: GOLDEN_JSON)
    response.define_singleton_method(:stop_reason) { "end_turn" }
    client = ClaudeChunkingClient.new(model: "claude-sonnet-4-6", client: FakeAnthropicClient.new(response: response))

    assert_enqueued_with(job: TrackBedrockQueryJob) do
      client.call(
        user_content:   [],
        filename:       "manual.pdf",
        page_number:    7,
        total_pages:    24,
        max_tokens:     16_000,
        tracking_prefix: "bulk_retry",
        attempt:        2,
        correlation_id: "ingest:abcdef123456:p7",
        route:          "bulk_retry"
      )
    end

    job_args = enqueued_jobs.last[:args].first
    assert_equal 16_000,                   job_args["max_tokens"]
    assert_equal "end_turn",               job_args["stop_reason"]
    assert_equal 2,                        job_args["attempt"]
    assert_equal "ingest:abcdef123456:p7", job_args["correlation_id"]
    assert_equal "bulk_retry",             job_args["route"]
  end

  test "tracking defaults: route sync, attempt 1, max_tokens = configured cap" do
    client = make_client(model: "claude-sonnet-4-6")

    assert_enqueued_with(job: TrackBedrockQueryJob) do
      client.call(user_content: [], filename: "doc.pdf")
    end

    job_args = enqueued_jobs.last[:args].first
    assert_equal "sync",                          job_args["route"]
    assert_equal 1,                               job_args["attempt"]
    assert_equal BatchChunkingPrompt::MAX_TOKENS, job_args["max_tokens"]
    assert_nil job_args["correlation_id"]
  end

  test "raw stop_reason max_tokens is recorded in telemetry (not normalized away)" do
    response = FakeResponse.new(text: GOLDEN_JSON)
    response.define_singleton_method(:stop_reason) { "max_tokens" }
    client = ClaudeChunkingClient.new(model: "claude-sonnet-4-6", client: FakeAnthropicClient.new(response: response))

    client.call(user_content: [], filename: "big.pdf", max_tokens: 8_000)

    job_args = enqueued_jobs.last[:args].first
    assert_equal "max_tokens", job_args["stop_reason"]
    assert_equal 8_000,        job_args["max_tokens"]
  end

  # ---------------------------------------------------------------------------
  # CreditBalanceError
  # ---------------------------------------------------------------------------

  test "raises CreditBalanceError (subclass of ApiError) when Anthropic returns credit balance error" do
    fake_client = FakeAnthropicClient.new(response: nil)
    err_class = Class.new(Anthropic::Errors::APIError) do
      def initialize = super(url: "https://api.anthropic.com/v1/messages", status: 400, body: {})
      def message    = "Your credit balance is too low to make this request."
    end
    fake_client.messages.define_singleton_method(:stream) { |_| raise err_class }

    client = ClaudeChunkingClient.new(model: "claude-opus-4-7", client: fake_client)

    assert_raises(ClaudeChunkingClient::CreditBalanceError) do
      client.call(user_content: [], filename: "big.pdf")
    end
  end

  test "CreditBalanceError is a subclass of ApiError" do
    assert ClaudeChunkingClient::CreditBalanceError < ClaudeChunkingClient::ApiError
  end

  test "logs ALERT for credit balance error" do
    fake_client = FakeAnthropicClient.new(response: nil)
    err_class = Class.new(Anthropic::Errors::APIError) do
      def initialize = super(url: "https://api.anthropic.com/v1/messages", status: 400, body: {})
      def message    = "Your credit balance is too low to make this request."
    end
    fake_client.messages.define_singleton_method(:stream) { |_| raise err_class }

    client = ClaudeChunkingClient.new(model: "claude-opus-4-7", client: fake_client)

    logged = []
    orig_error = Rails.logger.method(:error)
    Rails.logger.define_singleton_method(:error) { |msg| logged << msg; orig_error.call(msg) }

    assert_raises(ClaudeChunkingClient::CreditBalanceError) do
      client.call(user_content: [], filename: "x.pdf")
    end

    assert logged.any? { |m| m.include?("ALERT anthropic_credit_balance_low") },
           "expected ALERT log for credit balance error, got: #{logged.inspect}"
  ensure
    Rails.logger.define_singleton_method(:error, orig_error) if defined?(orig_error)
  end
end
