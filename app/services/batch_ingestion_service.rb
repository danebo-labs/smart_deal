# frozen_string_literal: true

require "aws-sdk-s3"

# Orchestrates the two phases of bulk ZIP ingestion.
#
# Phase 1 — process!(bulk_upload, zip_path):
#   Extract ZIP → compress images → upload originals to S3 → create BulkUploadAsset rows.
#   Called by ProcessBulkUploadJob.
#
# Phase 2 — submit!(bulk_upload):
#   Download assets from S3 → build Anthropic batch requests → submit batch →
#   persist claude_batch_id → mark assets in_batch.
#   Called by SubmitClaudeBatchJob.
class BatchIngestionService
  include AwsClientInitializer

  def initialize(batch_client: nil)
    @batch_client = batch_client || ClaudeBatchClient.new
    client_options = build_aws_client_options
    @s3     = Aws::S3::Client.new(client_options)
    @bucket = bucket_name
  end

  # Phase 1: extract ZIP, upload originals to S3, create asset rows.
  # @param bulk_upload [BulkUpload]
  # @param zip_path    [String] path to the ZIP file on disk
  def process!(bulk_upload, zip_path)
    date_prefix = Date.current.iso8601

    ZipExtractionService.new(zip_path).each_entry do |entry|
      binary = compress_if_image(entry[:binary], entry[:content_type])
      key    = "bulk_uploads/#{date_prefix}/#{entry[:filename]}"
      upload_binary(key, binary, entry[:content_type])

      asset = BulkUploadAsset.find_or_initialize_by(
        custom_id: BulkUploadAsset.custom_id_for(entry[:binary])
      )

      dedup = ContentDedupService.find_completed(sha256: entry[:sha256])

      if dedup.hit
        asset.assign_attributes(
          bulk_upload:    bulk_upload,
          sha256:         entry[:sha256],
          s3_key:         key,
          filename:       entry[:filename],
          content_type:   entry[:content_type],
          canonical_name: dedup.canonical_name,
          aliases:        dedup.aliases,
          ingestion_path: BulkUploadAsset::INGESTION_CONTENT_DEDUP,
          status:         "complete"
        )
        created = !asset.persisted?
        asset.save!
        asset.broadcast_append! if created
        backfill_thumbnail_if_image(asset)
        Rails.logger.info("BatchIngestionService: dedup hit #{entry[:filename]} sha=#{entry[:sha256][0, 16]}")
        next
      end

      asset.assign_attributes(
        bulk_upload:  bulk_upload,
        sha256:       entry[:sha256],
        s3_key:       key,
        filename:     entry[:filename],
        content_type: entry[:content_type],
        office_origin: entry[:office_origin] || false,
        status:       "uploaded_s3"
      )
      created = !asset.persisted?
      asset.save!
      asset.broadcast_append! if created
    end

    bulk_upload.update!(status: "processing")
  end

  # Phase 2: build Anthropic batch requests from uploaded assets and submit.
  # @param bulk_upload [BulkUpload]
  # @return [Anthropic::Models::Messages::MessageBatch]
  def submit!(bulk_upload)
    assets = bulk_upload.bulk_upload_assets.where(status: "uploaded_s3")

    if cost_v2_enabled?
      requests, meta = BulkCostV2RequestBuilder.new.build_all!(assets)
      batch = @batch_client.submit_batch(requests: requests)
      bulk_upload.update!(claude_batch_id: batch.id)
      persist_batch_custom_ids!(assets, meta)
    else
      requests = build_requests(assets)
      batch    = @batch_client.submit_batch(requests: requests)
      bulk_upload.update!(claude_batch_id: batch.id)
      assets.update_all(status: "in_batch")
    end

    batch
  end

  private

  def cost_v2_enabled?
    ENV["CUSTOM_CHUNKING_COST_V2_ENABLED"].to_s == "true"
  end

  def persist_batch_custom_ids!(assets, meta)
    assets.each do |asset|
      page_ids = Array(meta[asset.id])
      asset.update_columns(
        batch_custom_ids: page_ids,
        ingestion_path:   detect_ingestion_path(asset, page_ids),
        status:           "in_batch"
      )
      asset.broadcast_replace!
    end
  end

  def detect_ingestion_path(asset, page_ids)
    if %w[image/jpeg image/png image/webp image/gif].include?(asset.content_type)
      "field_photo_v1"
    elsif page_ids.any? { |id| id.include?("_p") }
      "manual_batch_v1"
    else
      "batch_v1"
    end
  end

  def build_requests(assets)
    assets.map do |asset|
      binary = download_binary(asset.s3_key)
      {
        custom_id: asset.custom_id,
        params: {
          model:      BatchChunkingPrompt::MODEL,
          max_tokens: BatchChunkingPrompt::MAX_TOKENS,
          system:     BatchChunkingPrompt::SYSTEM_BLOCKS,
          messages: [
            {
              role:    "user",
              content: BatchChunkingPrompt.user_content(
                binary:       binary,
                content_type: asset.content_type,
                filename:     asset.filename
              )
            }
          ]
        }
      }
    end
  end

  def backfill_thumbnail_if_image(asset)
    return unless %w[image/jpeg image/jpg image/png image/webp image/gif].include?(asset.content_type.to_s)

    kb_doc = asset.kb_document_id ? KbDocument.find_by(id: asset.kb_document_id)
                                   : KbDocument.find_by(s3_key: asset.s3_key)
    KbDocumentThumbnailFromS3.call(kb_doc) if kb_doc
  rescue StandardError => e
    Rails.logger.warn("BatchIngestionService: thumbnail backfill failed for asset #{asset.id} — #{e.message}")
  end

  def compress_if_image(binary, content_type)
    return binary if content_type == "application/pdf"

    result = ImageCompressionService.compress(Base64.strict_encode64(binary), content_type)
    result[:binary]
  rescue ImageCompressionService::CompressionError => e
    Rails.logger.warn("BatchIngestionService: compression failed, using original — #{e.message}")
    binary
  end

  def upload_binary(key, binary, content_type)
    @s3.put_object(bucket: @bucket, key: key, body: binary, content_type: content_type)
    key
  end

  def download_binary(key)
    @s3.get_object(bucket: @bucket, key: key).body.read
  end

  def bucket_name
    ENV["KNOWLEDGE_BASE_S3_BUCKET"].presence ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
      Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
      "document-chatbot-generic-tech-info"
  end
end
