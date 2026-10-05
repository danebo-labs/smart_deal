# frozen_string_literal: true

# Benchmark-only Field Companion generation for Grok 4.7 on Bedrock Converse.
# Installed by the F1 runner when F1CAL_GROK=1. Production query generation
# stays on BedrockClient#generate_text and the Haiku default.

module FieldCompanion
  module F1GrokGeneration
    MODEL_ID = "global.xai.grok-4.7"
    REASONING_EFFORT = "low"
    PREFLIGHT_PROMPT = "Return exactly: PREFLIGHT_OK"
    # Per 1k tokens, matching BedrockQuery#cost. Global CRIS Standard:
    # $2 / $6 / $0.50 cache read per 1M tokens.
    PRICING = { input: 0.002, output: 0.006, cache_read: 0.0005 }.freeze

    class Error < StandardError; end

    module Adapter
      def generate_text(prompt, model_id: DEFAULT_MODEL_ID, max_tokens: 2000, temperature: 0.7, tracking: nil)
        model_id ||= DEFAULT_MODEL_ID
        return super unless model_id == F1GrokGeneration::MODEL_ID

        F1GrokGeneration.converse(
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

    def request(prompt:, max_tokens:, temperature:)
      {
        model_id: MODEL_ID,
        messages: [ { role: "user", content: [ { text: prompt.to_s } ] } ],
        inference_config: { max_tokens: max_tokens, temperature: temperature },
        additional_model_request_fields: { reasoning_effort: REASONING_EFFORT }
      }
    end

    def converse(client:, prompt:, max_tokens:, temperature:, tracking: nil)
      started = Time.current
      response = client.converse(**request(prompt: prompt, max_tokens: max_tokens, temperature: temperature))
      latency_ms = ((Time.current - started) * 1000).to_i
      content = response.output.message.content
      text = answer_text(content)
      raise Error, "blank Grok answer model=#{MODEL_ID} stop=#{response.stop_reason}" if text.blank?

      counts = usage_counts(response.usage)
      raise Error, "Grok usage missing input tokens model=#{MODEL_ID}" if counts[:input_tokens] <= 0

      usd = cost_usd(**counts.slice(:input_tokens, :output_tokens, :cache_read_tokens))
      raise Error, "Grok pricing returned zero model=#{MODEL_ID}" if usd <= 0

      meta = {
        model_id: MODEL_ID,
        reasoning_effort: REASONING_EFFORT,
        stop_reason: response.stop_reason.to_s,
        reasoning_chars: reasoning_chars(content),
        reasoning_tokens: reasoning_tokens_from(response.additional_model_response_fields),
        additional: jsonable(response.additional_model_response_fields),
        latency_ms: latency_ms
      }
      (Thread.current[:f1_grok_calls] ||= []) << meta
      enqueue(prompt: prompt, max_tokens: max_tokens, tracking: tracking, counts: counts, latency_ms: latency_ms, stop_reason: response.stop_reason)
      meta.merge(text: text, usage: counts, cost_usd: usd)
    end

    def answer_text(content)
      Array(content).filter_map { |block| visible_text(block) }.join.strip
    end

    def cost_usd(input_tokens:, output_tokens:, cache_read_tokens: 0)
      (input_tokens.to_i / 1000.0 * PRICING[:input]) +
        (output_tokens.to_i / 1000.0 * PRICING[:output]) +
        (cache_read_tokens.to_i / 1000.0 * PRICING[:cache_read])
    end

    def usage_counts(usage)
      {
        input_tokens: usage.input_tokens.to_i,
        output_tokens: usage.output_tokens.to_i,
        cache_read_tokens: usage.cache_read_input_tokens.to_i,
        cache_write_tokens: usage.cache_write_input_tokens.to_i
      }
    end

    def visible_text(block)
      return if reasoning_block?(block)

      text = read(block, :text)
      return text if text.present?

      citations = read(block, :citations_content)
      return if citations.nil?

      answer_text(read(citations, :content))
    end

    def reasoning_block?(block)
      read(block, :reasoning_content).present? && read(block, :text).blank?
    end

    def reasoning_chars(content)
      Array(content).sum { |block| reasoning_body(block).to_s.length }
    end

    def reasoning_body(block)
      reasoning = read(block, :reasoning_content)
      return if reasoning.nil?

      text = read(reasoning, :reasoning_text)
      read(text, :text)
    end

    def reasoning_tokens_from(additional)
      found = nil
      walk = lambda do |node|
        case node
        when Hash
          node.each do |key, value|
            if %w[reasoning_tokens reasoningTokens reasoning_output_tokens].include?(key.to_s) && value.is_a?(Numeric)
              found = value.to_i
            else
              walk.call(value)
            end
          end
        when Array
          node.each { |value| walk.call(value) }
        end
      end
      walk.call(jsonable(additional))
      found
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
        cache_creation_tokens: counts[:cache_write_tokens],
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

    def read(object, key)
      return if object.nil?
      return object[key] || object[key.to_s] if object.is_a?(Hash)
      return object.public_send(key) if object.respond_to?(key)

      nil
    end

    def jsonable(value)
      case value
      when nil, String, Numeric, TrueClass, FalseClass
        value
      when Hash
        value.to_h { |key, inner| [ key.to_s, jsonable(inner) ] }
      when Array
        value.map { |inner| jsonable(inner) }
      else
        value.respond_to?(:to_h) ? jsonable(value.to_h) : value.to_s
      end
    end
  end
end
