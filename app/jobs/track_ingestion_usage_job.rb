# frozen_string_literal: true

# app/jobs/track_ingestion_usage_job.rb
#
# Estimates and persists Bedrock token usage for each document ingested into
# the Knowledge Base:
#   - 1 BedrockQuery (source: :ingestion_parse) for Opus foundation model parsing
#   - 1 BedrockQuery (source: :ingestion_embed) for Nova multimodal embedding
#
# Called from BedrockIngestionJob after status COMPLETE.
# Idempotent: skips a filename if a :ingestion_parse record for it was
# already created within the last 5 minutes (handles job retries).
class TrackIngestionUsageJob < ApplicationJob
  queue_as :default

  OPUS_MODEL_ID  = "global.anthropic.claude-opus-4-6-v1"
  NOVA_MODEL_ID  = "amazon.nova-2-multimodal-embeddings-v1:0"
  IDEMPOTENCY_WINDOW = 5.minutes

  def perform(uploaded_filenames:, ingestion_job_id: nil, kb_id: nil, data_source_id: nil)
    bucket = ENV.fetch("KNOWLEDGE_BASE_S3_BUCKET", "multimodal-source-destination")
    s3     = build_s3_client

    Array(uploaded_filenames).compact.each do |fname|
      next if already_tracked?(fname)

      bytes = fetch_from_s3(s3, bucket, fname)
      next if bytes.nil?

      usage = IngestionTokenEstimator.estimate(filename: fname, bytes: bytes)
      persist_usage(fname, usage)
    end

    SimpleMetricsService.update_database_metrics_only
    broadcast_metrics_update
  rescue StandardError => e
    Rails.logger.error("[TrackIngestionUsageJob] failed: #{e.message}")
    raise
  end

  private

  # Guard: skip if an ingestion_parse record for this filename was created
  # in the last IDEMPOTENCY_WINDOW (handles retry storms).
  def already_tracked?(fname)
    query_label = "[parse] #{fname}".truncate(500)
    exists = BedrockQuery.exists?(
      source: :ingestion_parse,
      user_query: query_label,
      created_at: IDEMPOTENCY_WINDOW.ago..
    )
    Rails.logger.info("[TrackIngestionUsageJob] skipping #{fname} (already tracked)") if exists
    exists
  end

  def fetch_from_s3(s3, bucket, fname)
    m      = fname.match(/\A(?:wa|chat)_(\d{4})(\d{2})(\d{2})_/)
    date   = m ? "#{m[1]}-#{m[2]}-#{m[3]}" : Date.current.iso8601
    key    = "uploads/#{date}/#{fname}"

    resp = s3.get_object(bucket: bucket, key: key)
    resp.body.read
  rescue Aws::S3::Errors::NoSuchKey
    Rails.logger.warn("[TrackIngestionUsageJob] S3 key not found: #{bucket}/#{key}")
    nil
  rescue StandardError => e
    Rails.logger.warn("[TrackIngestionUsageJob] S3 fetch failed for #{fname}: #{e.message}")
    nil
  end

  def persist_usage(fname, usage)
    BedrockQuery.create!(
      model_id:     OPUS_MODEL_ID,
      input_tokens: usage[:parse][:input_tokens],
      output_tokens: usage[:parse][:output_tokens],
      user_query:   "[parse] #{fname}".truncate(500),
      latency_ms:   0,
      source:       :ingestion_parse
    )
    BedrockQuery.create!(
      model_id:     NOVA_MODEL_ID,
      input_tokens: usage[:embed][:input_tokens],
      output_tokens: 0,
      user_query:   "[embed] #{fname}".truncate(500),
      latency_ms:   0,
      source:       :ingestion_embed
    )
    Rails.logger.info(
      "[TrackIngestionUsageJob] tracked #{fname} — " \
      "parse #{usage[:parse][:input_tokens]}in/#{usage[:parse][:output_tokens]}out " \
      "embed #{usage[:embed][:input_tokens]}in"
    )
  rescue StandardError => e
    Rails.logger.error("[TrackIngestionUsageJob] failed to persist for #{fname}: #{e.message}")
  end

  def broadcast_metrics_update
    TrackBedrockQueryJob.new.send(:broadcast_metrics_update)
  rescue StandardError => e
    Rails.logger.warn("[TrackIngestionUsageJob] broadcast failed: #{e.message}")
  end

  def build_s3_client
    require "aws-sdk-s3"
    opts = {}
    opts[:region] = ENV["AWS_REGION"].presence || "us-east-1"
    key    = ENV["AWS_ACCESS_KEY_ID"].presence    || Rails.application.credentials.dig(:aws, :access_key_id)
    secret = ENV["AWS_SECRET_ACCESS_KEY"].presence || Rails.application.credentials.dig(:aws, :secret_access_key)
    opts[:credentials] = Aws::Credentials.new(key, secret) if key && secret
    Aws::S3::Client.new(opts)
  end
end
