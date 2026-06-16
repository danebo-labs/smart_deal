# frozen_string_literal: true

require "aws-sdk-s3"

# Orchestrates the two phases of bulk ZIP ingestion.
#
# Phase 1 — process!(bulk_upload, zip_path):
#   Extract ZIP → compress images → upload originals to S3 → create BulkUploadAsset rows.
#   Called by ProcessBulkUploadJob.
#
# Phase 2 — submit!(bulk_upload):
#   Download assets from S3 → build Anthropic batch requests (cost_v2 path) →
#   submit batch → persist claude_batch_id → mark assets in_batch.
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
  # Per-file MIME/Office failures create failed asset rows via record_skipped_asset!.
  # Global ZIP errors (bomb, size) propagate as ZipExtractionService::Error.
  # @param bulk_upload [BulkUpload]
  # @param zip_path    [String] path to the ZIP file on disk
  def process!(bulk_upload, zip_path)
    date_prefix = Date.current.iso8601
    extractor   = ZipExtractionService.new(zip_path)

    extractor.each_entry do |entry|
      binary = compress_if_image(entry[:binary], entry[:content_type],
                                  filename: entry[:filename], sha256: entry[:sha256])
      key    = "bulk_uploads/#{date_prefix}/#{entry[:filename]}"
      upload_binary(key, binary, entry[:content_type])

      asset = BulkUploadAsset.find_or_initialize_by(
        custom_id: BulkUploadAsset.custom_id_for(
          entry[:binary],
          contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
        )
      )

      dedup = ContentDedupService.find_completed(
        sha256: entry[:sha256],
        contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
      )

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
          ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
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
        bulk_upload:   bulk_upload,
        sha256:        entry[:sha256],
        s3_key:        key,
        filename:      entry[:filename],
        content_type:  entry[:content_type],
        office_origin: entry[:office_origin] || false,
        ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
        status:        "uploaded_s3"
      )
      created = !asset.persisted?
      asset.save!
      asset.broadcast_append! if created
    end

    extractor.skipped_entries.each { |skip| record_skipped_asset!(bulk_upload, skip) }

    bulk_upload.update!(status: "processing")
  end

  # Phase 2: build Anthropic batch requests from uploaded assets and submit.
  # Returns nil if there are no uploaded_s3 assets (all entries were skipped/failed).
  # @param bulk_upload [BulkUpload]
  # @return [Anthropic::Models::Messages::MessageBatch, nil]
  def submit!(bulk_upload)
    assets = bulk_upload.bulk_upload_assets.where(status: "uploaded_s3")
    return nil if assets.none?

    requests, meta = BulkCostV2RequestBuilder.new.build_all!(assets)
    batch = @batch_client.submit_batch(requests: requests)
    bulk_upload.update!(claude_batch_id: batch.id)
    persist_batch_custom_ids!(assets, meta)
    batch
  end

  private

  def record_skipped_asset!(bulk_upload, skip)
    asset = BulkUploadAsset.find_or_initialize_by(
      custom_id: BulkUploadAsset.custom_id_for(
        skip[:binary],
        contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
      )
    )
    asset.assign_attributes(
      bulk_upload:   bulk_upload,
      sha256:        skip[:sha256],
      filename:      skip[:filename],
      error_message: BulkUploadAssetErrorMessage.encode(skip[:reason_key], skip[:reason_params]),
      status:        "failed"
    )
    created = !asset.persisted?
    asset.save!
    asset.broadcast_append! if created
    asset.broadcast_replace! unless created
    Rails.logger.info(
      "BatchIngestionService: skipped #{skip[:filename]} — #{skip[:reason_key]} #{skip[:reason_params]}"
    )
  end

  def persist_batch_custom_ids!(assets, meta)
    assets.each do |asset|
      page_ids = Array(meta[asset.id])

      # All pages filtered out → mark failed, don't send to in_batch
      if page_ids.empty?
        asset.update_columns(
          status:        "failed",
          error_message: BulkUploadAssetErrorMessage.encode("bulk_uploads.all_pages_filtered", filename: asset.filename)
        )
        asset.broadcast_replace!
        Rails.logger.warn("BatchIngestionService: all pages filtered for #{asset.filename}")
        next
      end

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

  def backfill_thumbnail_if_image(asset)
    return unless %w[image/jpeg image/jpg image/png image/webp image/gif].include?(asset.content_type.to_s)

    kb_doc = asset.kb_document_id ? KbDocument.find_by(id: asset.kb_document_id)
                                   : KbDocument.find_by(s3_key: asset.s3_key)
    KbDocumentThumbnailFromS3.call(kb_doc) if kb_doc
  rescue StandardError => e
    Rails.logger.warn("BatchIngestionService: thumbnail backfill failed for asset #{asset.id} — #{e.message}")
  end

  def compress_if_image(binary, content_type, filename: nil, sha256: nil)
    return binary if content_type == "application/pdf"

    cid    = sha256 ? "ingest:#{sha256[0, 12]}" : nil
    result = ImageCompressionService.compress(
      Base64.strict_encode64(binary), content_type,
      filename: filename, correlation_id: cid
    )
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
