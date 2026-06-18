# frozen_string_literal: true

# Persists a BedrockQuery record and refreshes CostMetric counters asynchronously.
# Called from BedrockRagService and BedrockClient so that tracking never blocks
# the HTTP response.
#
# After updating CostMetric it broadcasts a Turbo Stream to the "metrics" channel
# so the home page metrics widget refreshes automatically in the browser.
class TrackBedrockQueryJob < ApplicationJob
  queue_as :default

  # @param model_id               [String]       Bedrock / Anthropic model identifier
  # @param input_tokens           [Integer, nil] Non-cached prompt tokens (precounted by caller)
  # @param output_tokens          [Integer, nil] Completion tokens (precounted by caller)
  # @param cache_read_tokens      [Integer, nil] Tokens served from prompt cache (cheaper rate)
  # @param cache_creation_tokens  [Integer, nil] Tokens written to prompt cache (slightly higher rate)
  # @param prompt_text            [String, nil]  Raw prompt; counted here when input_tokens is nil
  # @param answer_text            [String, nil]  Raw billed answer; counted here when output_tokens is nil
  # @param visible_answer_text    [String, nil]  Answer returned to the user after hidden metadata is removed
  # @param regression_context     [Hash, nil]    RAG settings and observed chunk identity for regression analysis
  # @param user_query             [String]       Original user question (truncated to 500 chars)
  # @param latency_ms             [Integer]      End-to-end latency of the API call in ms
  # @param source                 [String]       "query" | "ingestion_parse" | "ingestion_embed"
  # @param model_for_counting     [Symbol]       Tokenizer model when counting here (default :haiku)
  # @param route                  [String, nil]  Billing route ("sync"|"batch"|"bulk_retry"|"page_filter"|
  #                                              "rag_filtered"|"rag_global"|"query_direct")
  # @param attempt                [Integer, nil] 1-based attempt within the same logical unit
  # @param max_tokens             [Integer, nil] Configured output cap (ladder rung) for this invocation
  # @param stop_reason            [String, nil]  Raw provider stop reason
  # @param correlation_id         [String, nil]  Groups all attempts of one page/document/query
  def perform(model_id:, user_query:, latency_ms:,
              input_tokens: nil, output_tokens: nil,
              cache_read_tokens: nil, cache_creation_tokens: nil,
              prompt_text: nil, answer_text: nil, visible_answer_text: nil,
              regression_context: nil,
              route: nil, attempt: nil, max_tokens: nil,
              stop_reason: nil, correlation_id: nil,
              source: "query", model_for_counting: :haiku)
    # Provider usage rows are exact. Reconstructed rows are estimates; current
    # reconciliation measured ~3.8% average query-cost undercount, with larger
    # hybrid-query outliers. Commercial reporting must preserve this label.
    token_source = input_tokens && output_tokens ? "provider_usage" : "estimated"

    if input_tokens.nil? || output_tokens.nil?
      usage = AnthropicTokenCounter.count_query(
        prompt: prompt_text.to_s,
        answer: answer_text.to_s,
        model:  model_for_counting.to_sym
      )
      input_tokens  ||= usage[:input_tokens]
      output_tokens ||= usage[:output_tokens]
    end

    bedrock_query = BedrockQuery.create!(
      model_id:              model_id,
      input_tokens:          input_tokens,
      output_tokens:         output_tokens,
      cache_read_tokens:     cache_read_tokens.presence,
      cache_creation_tokens: cache_creation_tokens.presence,
      user_query:            user_query.to_s.truncate(500),
      latency_ms:            latency_ms,
      route:                 route.presence,
      attempt:               attempt,
      max_tokens:            max_tokens,
      stop_reason:           stop_reason.presence,
      correlation_id:        correlation_id.presence,
      token_source:          token_source,
      source:                source.to_s
    )

    SimpleMetricsService.update_database_metrics_only

    broadcast_metrics_update

    Rails.logger.info(
      "[TrackBedrockQueryJob] tracked #{input_tokens} in + #{output_tokens} out tokens " \
      "(#{latency_ms}ms, model: #{model_id})"
    )

    log_regression_telemetry(
      regression_context: regression_context,
      raw_answer_text: answer_text,
      visible_answer_text: visible_answer_text,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model_for_counting: model_for_counting,
      bedrock_query_id: bedrock_query.id,
      model_id: model_id,
      latency_ms: latency_ms
    )
  end

  private

  def log_regression_telemetry(regression_context:, raw_answer_text:, visible_answer_text:,
                               input_tokens:, output_tokens:, model_for_counting:,
                               bedrock_query_id:, model_id:, latency_ms:)
    return if regression_context.blank?

    visible_tokens =
      if visible_answer_text.nil?
        nil
      elsif visible_answer_text.to_s == raw_answer_text.to_s
        output_tokens
      else
        AnthropicTokenCounter.count(
          text: visible_answer_text.to_s,
          model: model_for_counting.to_sym
        )
      end

    payload = regression_context.to_h.deep_stringify_keys.merge(
      "bedrock_query_id" => bedrock_query_id,
      "model_id" => model_id,
      "latency_ms" => latency_ms,
      "input_tokens_estimate" => input_tokens,
      "raw_output_tokens" => output_tokens,
      "visible_output_tokens" => visible_tokens,
      "hidden_output_tokens" => visible_tokens.nil? ? nil : [ output_tokens.to_i - visible_tokens.to_i, 0 ].max,
      "raw_output_chars" => raw_answer_text.to_s.length,
      "visible_output_chars" => visible_answer_text.to_s.length
    )

    max_tokens = payload["configured_max_tokens"].to_i
    if max_tokens.positive?
      payload["raw_output_utilization"] = (output_tokens.to_f / max_tokens).round(4)
      payload["possible_truncation"] = output_tokens.to_i >= (max_tokens * 0.95).floor
    end

    Rails.logger.info("[RAG_REGRESSION] #{JSON.generate(payload)}")
  end

  # Pushes Turbo Stream update to #chat-usage-metrics-container (home chat footer).
  # Subscribes via `turbo_stream_from "metrics"`.
  def broadcast_metrics_update
    Turbo::StreamsChannel.broadcast_update_to(
      "metrics",
      target: "chat-usage-metrics-container",
      partial: "home/chat_usage_footer_metrics",
      locals: { current_metrics: CostMetric.daily_snapshot(Date.current) }
    )
  rescue StandardError => e
    Rails.logger.warn("[TrackBedrockQueryJob] metrics broadcast failed: #{e.message}")
  end
end
