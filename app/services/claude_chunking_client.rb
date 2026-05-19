# frozen_string_literal: true

# Anthropic Messages API wrapper for the web custom chunking path — streaming mode.
# Contrast with ClaudeBatchClient (async Batch API used by bulk ingestion).
#
# Uses messages.stream (SSE) instead of messages.create because MAX_TOKENS=32_000
# exceeds the SDK's non-streaming threshold (~21_333 tokens), which would raise
# ArgumentError locally before any HTTP call is made.
# accumulated_message blocks until the full stream is consumed — same wall-clock
# semantics as create for a Solid Queue worker, no behavioural change for callers.
#
# One instance per model. Reuse across pages of the same document for efficiency
# (Anthropic caches the system prompt across calls from the same client).
#
# Emits one TrackBedrockQueryJob per call with:
#   model_id: "#{model}-direct"  (distinguishes direct-API cost from batch-API cost)
#   user_query: "web_parse: #{filename}" or "web_parse: #{filename} p#{N}/#{M}"
#   latency_ms: real wall-clock latency (unlike bulk path which sets 0)
#   source: "ingestion_parse"
class ClaudeChunkingClient
  class ApiError < StandardError; end

  # @param model      [String]  Anthropic model ID, e.g. BatchChunkingPrompt::MODEL_MULTIMODAL
  # @param client     [#messages] injectable Anthropic client (default: Anthropic::Client)
  def initialize(model:, client: nil)
    @model  = model
    @client = client || build_client
  end

  # @param user_content  [Array<Hash>] content blocks for the user turn
  # @param filename      [String]      original filename (for tracking)
  # @param page_number   [Integer, nil] current page number (for pdf_mixed tracking)
  # @param total_pages   [Integer, nil] total pages in this document (for pdf_mixed tracking)
  # @param max_tokens    [Integer]     token cap; defaults to MAX_TOKENS (32k) for single-shot paths;
  #   callers that process ≤1 page pass WEB_PAGE_MAX_TOKENS (4k) with retry logic
  # @return [Hash] { text: String, usage: usage_object, model: String, stop_reason: String | nil }
  # @raise [ApiError]
  def call(user_content:, filename:, page_number: nil, total_pages: nil,
           max_tokens: BatchChunkingPrompt::MAX_TOKENS)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    response = @client.messages.stream(
      model:      @model,
      max_tokens: max_tokens,
      system:     BatchChunkingPrompt::SYSTEM_BLOCKS,
      messages:   [ { role: "user", content: user_content } ]
    ).accumulated_message

    latency_ms  = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
    text_block  = response.content.find { |b| b.type.to_s == "text" }
    raise ApiError, "No text block in Anthropic response (model=#{@model})" unless text_block

    raw_stop    = response.respond_to?(:stop_reason) ? response.stop_reason.to_s : nil
    stop_reason = raw_stop == "max_tokens" ? "max_tokens" : nil

    if stop_reason == "max_tokens"
      Rails.logger.warn(
        "ClaudeChunkingClient: #{@model} hit max_tokens cap (#{max_tokens}) " \
        "for #{user_query_for_log(filename, page_number, total_pages)}"
      )
    end

    track_usage(response.usage, filename, page_number, total_pages, latency_ms)

    { text: text_block.text, usage: response.usage, model: response.model, stop_reason: stop_reason }
  rescue Anthropic::Errors::APIError => e
    raise ApiError, "Anthropic API error (model=#{@model}): #{e.message}"
  rescue ArgumentError => e
    raise ApiError, "Anthropic client error (model=#{@model}): #{e.message}"
  end

  private

  def build_client
    api_key = ENV.fetch("ANTHROPIC_API_KEY", nil).presence ||
              Rails.application.credentials.dig(:anthropic, :api_key)
    Anthropic::Client.new(api_key: api_key)
  end

  def user_query_for_log(filename, page_number, total_pages)
    page_number && total_pages ? "#{filename} p#{page_number}/#{total_pages}" : filename
  end

  def track_usage(usage, filename, page_number, total_pages, latency_ms)
    user_query = if page_number && total_pages
      "web_parse: #{filename} p#{page_number}/#{total_pages}"
    else
      "web_parse: #{filename}"
    end

    TrackBedrockQueryJob.perform_later(
      model_id:              "#{@model}-direct",
      user_query:            user_query,
      latency_ms:            latency_ms,
      input_tokens:          usage.input_tokens.to_i,
      output_tokens:         usage.output_tokens.to_i,
      cache_read_tokens:     safe_token(usage, :cache_read_input_tokens),
      cache_creation_tokens: safe_token(usage, :cache_creation_input_tokens),
      source:                "ingestion_parse"
    )
  rescue StandardError => e
    Rails.logger.warn("ClaudeChunkingClient: failed to enqueue TrackBedrockQueryJob — #{e.message}")
  end

  def safe_token(usage, method_name)
    val = usage.respond_to?(method_name) ? usage.public_send(method_name).to_i : 0
    val.positive? ? val : nil
  end
end
