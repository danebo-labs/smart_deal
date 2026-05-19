# frozen_string_literal: true

# app/jobs/track_ingestion_usage_job.rb
#
# Estimates and persists Bedrock token usage for each document ingested into
# the Knowledge Base:
#
#   Legacy path (Bedrock FM parse on raw upload):
#     - 1 BedrockQuery (source: :ingestion_parse) for Opus foundation model parsing
#     - 1 BedrockQuery (source: :ingestion_embed) for Nova multimodal embedding
#
#   Custom chunking (web_v1 — chunks already written, chunking=NONE on bulk DS):
#     - Parse tokens are NOT estimated here; they are recorded by TrackBedrockQueryJob
#       when ClaudeChunkingClient runs (claude-*-direct, source: :ingestion_parse).
#     - Only Nova embed estimate is persisted (Bedrock still embeds chunk files).
#
# Called from BedrockIngestionJob after status COMPLETE.
# Idempotent: skips a filename if parse or embed was already tracked within the window.
class TrackIngestionUsageJob < ApplicationJob
  queue_as :default

  OPUS_MODEL_ID  = "global.anthropic.claude-opus-4-6-v1"
  NOVA_MODEL_ID  = "amazon.nova-2-multimodal-embeddings-v1:0"
  IDEMPOTENCY_WINDOW = 5.minutes

  def perform(uploaded_filenames:, ingestion_job_id: nil, kb_id: nil, data_source_id: nil,
              web_v1_metadata: nil)
    bucket = ENV.fetch("KNOWLEDGE_BASE_S3_BUCKET", "multimodal-source-destination")
    s3     = build_s3_client
    web_v1_filenames = web_v1_filename_set(web_v1_metadata)

    Array(uploaded_filenames).compact.each do |fname|
      next if already_tracked?(fname)

      bytes = fetch_from_s3(s3, bucket, fname)
      next if bytes.nil?

      usage = IngestionTokenEstimator.estimate(filename: fname, bytes: bytes)

      if web_v1_filenames.include?(fname)
        persist_web_v1_usage(fname, usage)
      else
        persist_legacy_usage(fname, usage)
      end
    end

    SimpleMetricsService.update_database_metrics_only
    broadcast_metrics_update
  rescue StandardError => e
    Rails.logger.error("[TrackIngestionUsageJob] failed: #{e.message}")
    raise
  end

  private

  def web_v1_filename_set(web_v1_metadata)
    Array(web_v1_metadata).filter_map do |entry|
      h = entry.respond_to?(:stringify_keys) ? entry.stringify_keys : entry.to_h.stringify_keys
      h["filename"].presence
    end.to_set
  end

  # Guard: skip if parse or embed for this filename was created recently (retries).
  def already_tracked?(fname)
    since = IDEMPOTENCY_WINDOW.ago
    parse_label = "[parse] #{fname}".truncate(500)
    embed_label = "[embed] #{fname}".truncate(500)

    exists = BedrockQuery.exists?(
      source: :ingestion_parse,
      user_query: parse_label,
      created_at: since..
    ) || BedrockQuery.exists?(
      source: :ingestion_embed,
      user_query: embed_label,
      created_at: since..
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

  def persist_legacy_usage(fname, usage)
    BedrockQuery.create!(
      model_id:      OPUS_MODEL_ID,
      input_tokens:  usage[:parse][:input_tokens],
      output_tokens: usage[:parse][:output_tokens],
      user_query:    "[parse] #{fname}".truncate(500),
      latency_ms:    0,
      source:        :ingestion_parse
    )
    persist_embed(fname, usage)
    Rails.logger.info(
      "[TrackIngestionUsageJob] legacy #{fname} — " \
      "parse #{usage[:parse][:input_tokens]}in/#{usage[:parse][:output_tokens]}out " \
      "embed #{usage[:embed][:input_tokens]}in"
    )
  rescue StandardError => e
    Rails.logger.error("[TrackIngestionUsageJob] failed to persist legacy for #{fname}: #{e.message}")
  end

  # web_v1: direct Claude parse is already in bedrock_queries (web_parse: …).
  def persist_web_v1_usage(fname, usage)
    persist_embed(fname, usage)
    Rails.logger.info(
      "[TrackIngestionUsageJob] web_v1 #{fname} — parse skipped (direct API tracked); " \
      "embed #{usage[:embed][:input_tokens]}in"
    )
  rescue StandardError => e
    Rails.logger.error("[TrackIngestionUsageJob] failed to persist web_v1 for #{fname}: #{e.message}")
  end

  def persist_embed(fname, usage)
    BedrockQuery.create!(
      model_id:      NOVA_MODEL_ID,
      input_tokens:  usage[:embed][:input_tokens],
      output_tokens: 0,
      user_query:    "[embed] #{fname}".truncate(500),
      latency_ms:    0,
      source:        :ingestion_embed
    )
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
