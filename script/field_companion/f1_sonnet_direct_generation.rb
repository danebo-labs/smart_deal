# frozen_string_literal: true

# Diagnostic-only Field Companion generation through the direct Anthropic
# Messages API. Installed only when F1CAL_SONNET_DIRECT=1. Production query
# generation stays on Bedrock Haiku. This file is not referenced from app/.

require "json"
require "net/http"

module FieldCompanion
  module F1SonnetDirectGeneration
    MODEL_ID = "claude-sonnet-5-5"
    TRACKING_MODEL_ID = "claude-sonnet-5-5-direct"
    THINKING_TYPE = "between_tools"
    GENERATION_MAX_TOKENS = 3000
    GENERATION_TEMPERATURE = 0.1
    PREFLIGHT_PROMPT = "Return exactly: PREFLIGHT_OK"
    ENDPOINT = URI("https://api.anthropic.com/v1/messages")
    ANTHROPIC_VERSION = "2023-06-01"
    # Same published direct rates as claude-sonnet-5-5-direct. Per 1k tokens.
    PRICING = { input: 0.002, output: 0.01, cache_read: 0.0002, cache_creation: 0.0025 }.freeze

    class Error < StandardError; end

    module Adapter
      def generate_text(prompt, model_id: DEFAULT_MODEL_ID, max_tokens: 2000, temperature: 0.7, tracking: nil)
        return super unless F1SonnetDirectGeneration.generation_call?(max_tokens: max_tokens, temperature: temperature)

        F1SonnetDirectGeneration.complete(
          prompt: prompt,
          max_tokens: max_tokens,
          temperature: temperature,
          tracking: tracking
        ).fetch(:text)
      end
    end

    module_function

    def install!
      BedrockClient.prepend(Adapter) unless BedrockClient.ancestors.include?(Adapter)
    end

    def generation_call?(max_tokens:, temperature:)
      max_tokens.to_i == GENERATION_MAX_TOKENS && temperature.to_f == GENERATION_TEMPERATURE
    end

    def request_body(prompt:, max_tokens:, temperature:)
      # Sonnet 5.5 rejects temperature on the direct API. The pipeline still
      # passes 0.1; that value selects the generation call and is not sent.
      temperature
      {
        model: MODEL_ID,
        max_tokens: max_tokens,
        thinking: { type: THINKING_TYPE },
        messages: [ { role: "user", content: prompt.to_s } ]
      }
    end

    def complete(prompt:, max_tokens:, temperature:, tracking: nil, poster: nil)
      body = request_body(prompt: prompt, max_tokens: max_tokens, temperature: temperature)
      raise Error, "Sonnet diagnostic must not enable adaptive thinking" if body.dig(:thinking, :type) != THINKING_TYPE
      raise Error, "Sonnet diagnostic must not send tools" if body.key?(:tools) || body.key?(:output_config)

      started = Time.current
      result = (poster || method(:post)).call(body)
      latency_ms = ((Time.current - started) * 1000).to_i
      text = answer_text(result["content"])
      raise Error, "blank Sonnet answer stop=#{result["stop_reason"]}" if text.blank?

      returned = result["model"].to_s
      raise Error, "Sonnet response omitted model" if returned.blank?
      raise Error, "Sonnet fell back to #{returned}" if returned.include?("haiku") || returned.exclude?("sonnet-5-5")

      counts = usage_counts(result["usage"])
      raise Error, "Sonnet usage missing input tokens" if counts[:input_tokens] <= 0

      usd = cost_usd(**counts)
      raise Error, "Sonnet pricing returned zero" if usd <= 0

      meta = {
        requested_model_id: MODEL_ID,
        returned_model: returned,
        thinking_type: THINKING_TYPE,
        transport: "anthropic_messages",
        stop_reason: result["stop_reason"].to_s,
        latency_ms: latency_ms
      }
      (Thread.current[:f1_sonnet_calls] ||= []) << meta
      enqueue(prompt: prompt, max_tokens: max_tokens, tracking: tracking, counts: counts, latency_ms: latency_ms, stop_reason: result["stop_reason"])
      meta.merge(text: text, usage: counts, cost_usd: usd)
    end

    def answer_text(content)
      Array(content).filter_map { |block|
        next unless block.is_a?(Hash)

        type = block["type"].to_s
        next if type == "thinking" || type == "redacted_thinking"

        block["text"] if type.empty? || type == "text"
      }.join.strip
    end

    def cost_usd(input_tokens:, output_tokens:, cache_read_tokens: 0, cache_creation_tokens: 0)
      (input_tokens.to_i / 1000.0 * PRICING[:input]) +
        (output_tokens.to_i / 1000.0 * PRICING[:output]) +
        (cache_read_tokens.to_i / 1000.0 * PRICING[:cache_read]) +
        (cache_creation_tokens.to_i / 1000.0 * PRICING[:cache_creation])
    end

    def usage_counts(usage)
      usage = usage.to_h
      {
        input_tokens: usage["input_tokens"].to_i,
        output_tokens: usage["output_tokens"].to_i,
        cache_read_tokens: usage["cache_read_input_tokens"].to_i,
        cache_creation_tokens: usage["cache_creation_input_tokens"].to_i
      }
    end

    def post(body)
      key = api_key
      raise Error, "SONNET_DIRECT_ACCESS_BLOCKED" if key.blank?

      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 120
      request = Net::HTTP::Post.new(ENDPOINT)
      request["content-type"] = "application/json"
      request["x-api-key"] = key
      request["anthropic-version"] = ANTHROPIC_VERSION
      request.body = JSON.generate(body)
      response = http.request(request)
      parsed = JSON.parse(response.body.to_s)
      return parsed if response.is_a?(Net::HTTPSuccess)

      message = parsed.dig("error", "message").to_s
      raise Error, "Anthropic #{response.code} #{message}"
    end

    def api_key
      ENV["ANTHROPIC_API_KEY"].presence || Rails.application.credentials.dig(:anthropic, :api_key)
    end

    def enqueue(prompt:, max_tokens:, tracking:, counts:, latency_ms:, stop_reason:)
      extra = tracking.to_h.symbolize_keys
      route = extra.delete(:route) || "query_direct"
      attempt = extra.delete(:attempt) || 1
      token_source = extra.delete(:token_source) || "provider_usage"
      TrackBedrockQueryJob.perform_later(
        model_id: TRACKING_MODEL_ID,
        input_tokens: counts[:input_tokens],
        output_tokens: counts[:output_tokens],
        cache_read_tokens: counts[:cache_read_tokens],
        cache_creation_tokens: counts[:cache_creation_tokens],
        token_source: token_source,
        user_query: prompt.to_s.truncate(500),
        latency_ms: latency_ms,
        route: route,
        attempt: attempt,
        max_tokens: max_tokens,
        stop_reason: stop_reason.to_s.presence,
        source: "query",
        account_id: extra[:account_id],
        user_id: extra[:user_id],
        conversation_session_id: extra[:conversation_session_id],
        correlation_id: extra[:correlation_id]
      )
    end
  end
end
