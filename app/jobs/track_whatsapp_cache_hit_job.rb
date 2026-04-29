# frozen_string_literal: true

# app/jobs/track_whatsapp_cache_hit_job.rb
#
# Records a WhatsApp faceted-cache hit — i.e., a request served from
# Rag::WhatsappAnswerCache without invoking Bedrock.
#
# Estimates tokens_saved by averaging the last 50 real query costs.
# This gives users a realistic "cache savings" figure in the dashboard.
class TrackWhatsappCacheHitJob < ApplicationJob
  queue_as :default

  def perform(recipient:, route:)
    avg_tokens = BedrockQuery
      .where(source: :query)
      .order(created_at: :desc)
      .limit(50)
      .average("input_tokens + output_tokens")
      .to_i

    WhatsappCacheHit.create!(
      recipient:             recipient,
      route:                 route,
      tokens_saved_estimate: avg_tokens
    )

    SimpleMetricsService.update_database_metrics_only
    TrackBedrockQueryJob.new.send(:broadcast_metrics_update)
  rescue StandardError => e
    Rails.logger.warn("[TrackWhatsappCacheHitJob] failed: #{e.message}")
  end
end
