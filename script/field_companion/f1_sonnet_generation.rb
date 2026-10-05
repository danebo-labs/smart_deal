# frozen_string_literal: true

# Benchmark-only Field Companion generation for Claude Sonnet 5.5 on Bedrock.
# Same invoke_model Anthropic body as Haiku, plus the model's required
# substitute for thinking disabled. Installed only when F1CAL_SONNET=1.
# Production query generation stays on Haiku.

module FieldCompanion
  module F1SonnetGeneration
    MODEL_ID = "global.anthropic.claude-sonnet-5-5"
    THINKING_TYPE = "between_tools"
    PREFLIGHT_PROMPT = "Return exactly: PREFLIGHT_OK"
    # Per 1k tokens. Global CRIS Standard: $2 / $10 / $0.20 cache read /
    # $2.50 five-minute cache write per 1M tokens. Geo profiles are not used.
    PRICING = { input: 0.002, output: 0.01, cache_read: 0.0002, cache_creation: 0.0025 }.freeze

    class Error < StandardError; end

    module Adapter
      def generate_text(prompt, model_id: DEFAULT_MODEL_ID, max_tokens: 2000, temperature: 0.7, tracking: nil)
        model_id ||= DEFAULT_MODEL_ID
        return super unless model_id == F1SonnetGeneration::MODEL_ID

        F1SonnetGeneration.invoke(
          client: @client,
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

    def request_body(prompt:, max_tokens:, temperature:)
      {
        anthropic_version: "bedrock-2023-05-31",
        max_tokens: max_tokens,
        temperature: temperature,
        thinking: { type: THINKING_TYPE },
        messages: [ { role: "user", content: prompt.to_s } ]
      }
    end

    def invoke(client:, prompt:, max_tokens:, temperature:, tracking: nil)
      body = request_body(prompt: prompt, max_tokens: max_tokens, temperature: temperature)
      raise Error, "Sonnet benchmark must not enable adaptive thinking" if body.dig(:thinking, :type) != THINKING_TYPE
      raise Error, "Sonnet benchmark must not send tools" if body.key?(:tools) || body.key?(:output_config)

      started = Time.current
      response = client.invoke_model(
        model_id: MODEL_ID,
        content_type: "application/json",
        accept: "application/json",
        body: body.to_json
      )
      result = JSON.parse(response.body.read)
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
        stop_reason: result["stop_reason"].to_s,
        latency_ms: latency_ms
      }
      (Thread.current[:f1_sonnet_calls] ||= []) << meta
      enqueue(prompt: prompt, max_tokens: max_tokens, tracking: tracking, counts: counts, latency_ms: latency_ms, stop_reason: result["stop_reason"])
      meta.merge(text: text, usage: counts, cost_usd: usd, raw_usage: result["usage"])
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

    def enqueue(prompt:, max_tokens:, tracking:, counts:, latency_ms:, stop_reason:)
      extra = tracking.to_h.symbolize_keys
      route = extra.delete(:route) || "query_direct"
      attempt = extra.delete(:attempt) || 1
      token_source = extra.delete(:token_source) || "provider_usage"
      TrackBedrockQueryJob.perform_later(
        model_id: MODEL_ID,
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
