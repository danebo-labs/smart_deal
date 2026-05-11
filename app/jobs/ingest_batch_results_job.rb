# frozen_string_literal: true

# Streams JSONL results from Anthropic for a completed batch, then:
#   1. For each succeeded result → BatchResultsParserService (writes .txt to S3, asset → "parsed").
#   2. For errored/canceled results → marks asset failed.
#   3. After all results → BulkKbSyncService#sync! with the bulk data source, saves
#      bedrock_ingestion_job_id, transitions parsed assets to "syncing",
#      and enqueues PollBulkBedrockIngestionJob.
class IngestBatchResultsJob < ApplicationJob
  queue_as :bulk_ingestion
  discard_on ActiveRecord::RecordNotFound

  self.log_arguments = false

  def perform(bulk_upload_id)
    bulk_upload  = BulkUpload.find(bulk_upload_id)
    return if bulk_upload.status == "failed"

    parser       = BatchResultsParserService.new
    batch_client = ClaudeBatchClient.new
    asset_map    = bulk_upload.bulk_upload_assets.where(status: "in_batch").index_by(&:custom_id)

    batch_client.results_each(batch_id: bulk_upload.claude_batch_id) do |result|
      asset = asset_map[result.custom_id]
      unless asset
        Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: unknown custom_id=#{result.custom_id}")
        next
      end

      if result.result.type.to_s == "succeeded"
        parser.call(asset: asset, result: result)
        track_asset_usage(asset, result.result.message)
      else
        msg = "Batch result type '#{result.result.type}' for #{asset.filename}"
        asset.update_columns(status: "failed", error_message: msg)
        asset.broadcast_replace!
        Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: #{msg}")
      end
    end

    bulk_upload.bulk_upload_assets.where(status: "in_batch").find_each do |asset|
      msg = "No batch result returned for this asset (custom_id=#{asset.custom_id})"
      asset.update_columns(status: "failed", error_message: msg)
      asset.broadcast_replace!
      Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: #{msg}")
    end

    parsed_assets = bulk_upload.bulk_upload_assets.where(status: "parsed")
    unless parsed_assets.exists?
      Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: no parsed assets, skipping Bedrock sync")
      bulk_upload.derive_status!
      return
    end

    sync_result = BulkKbSyncService.new.sync!(uploaded_filenames: parsed_assets.pluck(:canonical_name))
    unless sync_result
      msg = "Bedrock sync did not start — check BEDROCK_KNOWLEDGE_BASE_ID, BEDROCK_BULK_DATA_SOURCE_ID / BEDROCK_DATA_SOURCE_ID, and AWS credentials."
      Rails.logger.error("IngestBatchResultsJob[#{bulk_upload_id}]: BulkKbSyncService returned nil — #{msg}")
      parsed_assets.find_each do |asset|
        asset.update_columns(status: "failed", error_message: msg)
        asset.broadcast_replace!
      end
      bulk_upload.update_columns(error_message: msg) if bulk_upload.error_message.blank?
      bulk_upload.derive_status!
      return
    end

    bulk_upload.update_columns(bedrock_ingestion_job_id: sync_result[:job_id])
    parsed_assets.update_all(status: "syncing")
    parsed_assets.reload.each(&:broadcast_replace!)

    PollBulkBedrockIngestionJob.set(wait: 5.seconds).perform_later(bulk_upload_id)
    Rails.logger.info("IngestBatchResultsJob[#{bulk_upload_id}]: sync started job=#{sync_result[:job_id]}")
  rescue StandardError => e
    Rails.logger.error("IngestBatchResultsJob[#{bulk_upload_id}]: #{e.message}")
    raise
  end

  private

  def track_asset_usage(asset, message)
    usage = message.respond_to?(:usage) ? message.usage : nil
    return if usage.nil?

    input_tokens       = usage.input_tokens.to_i
    output_tokens      = usage.output_tokens.to_i
    cache_read         = usage.respond_to?(:cache_read_input_tokens) ? usage.cache_read_input_tokens.to_i : 0
    cache_creation     = usage.respond_to?(:cache_creation_input_tokens) ? usage.cache_creation_input_tokens.to_i : 0

    asset.update_columns(
      claude_input_tokens:  input_tokens + cache_read + cache_creation,
      claude_output_tokens: output_tokens
    )

    TrackBedrockQueryJob.perform_later(
      model_id:              message.model,
      user_query:            "batch_parse: #{asset.filename}",
      latency_ms:            0,
      input_tokens:          input_tokens,
      output_tokens:         output_tokens,
      cache_read_tokens:     cache_read.positive?     ? cache_read     : nil,
      cache_creation_tokens: cache_creation.positive? ? cache_creation : nil,
      source:                "ingestion_parse"
    )
  end
end
