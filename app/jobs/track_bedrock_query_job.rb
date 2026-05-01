# frozen_string_literal: true

# Persists a BedrockQuery record and refreshes CostMetric counters asynchronously.
# Called from BedrockRagService and BedrockClient so that tracking never blocks
# the HTTP response.
#
# After updating CostMetric it broadcasts a Turbo Stream to the "metrics" channel
# so the home page metrics widget refreshes automatically in the browser.
class TrackBedrockQueryJob < ApplicationJob
  queue_as :default

  # @param model_id      [String]  Bedrock model identifier
  # @param input_tokens  [Integer, nil] Tokens in the prompt (precounted by caller, e.g. BedrockClient)
  # @param output_tokens [Integer, nil] Tokens in the completion (precounted by caller)
  # @param prompt_text   [String, nil]  Raw assembled prompt; counted here when input_tokens is nil
  # @param answer_text   [String, nil]  Raw answer; counted here when output_tokens is nil
  # @param user_query    [String]       Original user question (truncated to 500 chars)
  # @param latency_ms    [Integer]      End-to-end latency of the Bedrock call in ms
  # @param source        [String]       Origin: "query" | "ingestion_parse" | "ingestion_embed"
  # @param model_for_counting [Symbol]  Tokenizer model when counting here (default :haiku)
  def perform(model_id:, user_query:, latency_ms:,
              input_tokens: nil, output_tokens: nil,
              prompt_text: nil, answer_text: nil,
              source: "query", model_for_counting: :haiku)
    if input_tokens.nil? || output_tokens.nil?
      usage = AnthropicTokenCounter.count_query(
        prompt: prompt_text.to_s,
        answer: answer_text.to_s,
        model:  model_for_counting.to_sym
      )
      input_tokens  ||= usage[:input_tokens]
      output_tokens ||= usage[:output_tokens]
    end

    BedrockQuery.create!(
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      user_query: user_query.to_s.truncate(500),
      latency_ms: latency_ms,
      source: source.to_s
    )

    SimpleMetricsService.update_database_metrics_only

    broadcast_metrics_update

    Rails.logger.info(
      "[TrackBedrockQueryJob] tracked #{input_tokens} in + #{output_tokens} out tokens " \
      "(#{latency_ms}ms, model: #{model_id})"
    )
  end

  private

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
