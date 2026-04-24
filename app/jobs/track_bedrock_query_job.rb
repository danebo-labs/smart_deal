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
  # @param input_tokens  [Integer] Tokens in the prompt
  # @param output_tokens [Integer] Tokens in the completion
  # @param user_query    [String]  Original user question (truncated to 500 chars)
  # @param latency_ms    [Integer] End-to-end latency of the Bedrock call in ms
  def perform(model_id:, input_tokens:, output_tokens:, user_query:, latency_ms:)
    BedrockQuery.create!(
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      user_query: user_query.to_s.truncate(500),
      latency_ms: latency_ms
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
    today = Date.current
    s3_bytes = CostMetric.find_by(date: today, metric_type: :s3_total_size)&.value || 0

    current_metrics = {
      today_tokens:  CostMetric.find_by(date: today, metric_type: :daily_tokens)&.value  || 0,
      today_cost:    CostMetric.find_by(date: today, metric_type: :daily_cost)&.value    || 0,
      today_queries: CostMetric.find_by(date: today, metric_type: :daily_queries)&.value || 0,
      aurora_acu:    CostMetric.find_by(date: today, metric_type: :aurora_acu_avg)&.value || 0,
      s3_documents:  CostMetric.find_by(date: today, metric_type: :s3_documents_count)&.value || 0,
      s3_size_mb:    (s3_bytes / 1.megabyte.to_f).round(2),
      s3_size_gb:    (s3_bytes / 1.gigabyte.to_f).round(2)
    }

    Turbo::StreamsChannel.broadcast_update_to(
      "metrics",
      target: "chat-usage-metrics-container",
      partial: "home/chat_usage_footer_metrics",
      locals: { current_metrics: current_metrics }
    )
  rescue StandardError => e
    Rails.logger.warn("[TrackBedrockQueryJob] metrics broadcast failed: #{e.message}")
  end
end
