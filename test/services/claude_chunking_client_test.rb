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

    def initialize(text:, model: "claude-opus-4-7", usage: FakeUsage.new)
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

  def make_client(text: GOLDEN_JSON, model: "claude-opus-4-7", usage: FakeUsage.new)
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
    assert_equal "claude-opus-4-7",                   last[:model]
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
end
