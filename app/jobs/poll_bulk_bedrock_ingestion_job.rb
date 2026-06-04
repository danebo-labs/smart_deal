# frozen_string_literal: true

# Polls the Bedrock ingestion job for a BulkUpload until terminal status,
# then finalizes assets (complete / failed) and broadcasts Turbo Stream updates.
#
# Re-enqueue pattern: one status check per perform, frees the worker thread between polls.
# Backoff: 5s → 10s → 20s → … → cap 300s. Hard timeout 15 min.
class PollBulkBedrockIngestionJob < ApplicationJob
  queue_as :bulk_ingestion
  discard_on ActiveRecord::RecordNotFound

  self.log_arguments = false

  INITIAL_WAIT = 5
  MAX_WAIT     = 300
  HARD_TIMEOUT = 15.minutes

  def perform(bulk_upload_id, started_at_iso: nil, wait_seconds: INITIAL_WAIT)
    bulk_upload = BulkUpload.find(bulk_upload_id)
    return if bulk_upload.status == "failed"

    job_id = bulk_upload.bedrock_ingestion_job_id
    if job_id.blank?
      Rails.logger.warn("PollBulkBedrockIngestionJob[#{bulk_upload_id}]: missing bedrock_ingestion_job_id")
      return
    end

    started_at = started_at_iso.present? ? Time.zone.parse(started_at_iso) : Time.current

    if Time.current - started_at > HARD_TIMEOUT
      mark_timed_out(bulk_upload, job_id)
      return
    end

    service = ingestion_status_service
    status  = service.job_status(job_id)

    if status.in?(%w[COMPLETE FAILED STOPPED])
      finalize(bulk_upload, status, service, job_id)
    else
      next_wait = [ wait_seconds * 2, MAX_WAIT ].min
      self.class.set(wait: wait_seconds.seconds).perform_later(
        bulk_upload_id,
        started_at_iso: started_at.iso8601,
        wait_seconds:   next_wait
      )
      Rails.logger.info("PollBulkBedrockIngestionJob[#{bulk_upload_id}]: status=#{status}, re-enqueue in #{wait_seconds}s")
    end
  rescue StandardError => e
    Rails.logger.error("PollBulkBedrockIngestionJob[#{bulk_upload_id}]: #{e.message}")
    raise
  end

  private

  def ingestion_status_service
    bulk_ds_id = ENV["BEDROCK_BULK_DATA_SOURCE_ID"].presence ||
                 Rails.application.credentials.dig(:bedrock, :bulk_data_source_id)
    IngestionStatusService.new(data_source_id: bulk_ds_id)
  end

  def finalize(bulk_upload, status, service, job_id)
    service.clear_when_complete(job_id)
    syncing_assets = bulk_upload.bulk_upload_assets.where(status: "syncing").to_a

    if status == "COMPLETE"
      syncing_assets.each do |asset|
        kb_doc = upsert_kb_document(asset)
        asset.update_columns(status: "complete", kb_document_id: kb_doc&.id)
        asset.broadcast_replace!
      end
    else
      msg = "Bedrock ingestion #{status.downcase} for job #{job_id}"
      syncing_assets.each do |asset|
        asset.update_columns(status: "failed", error_message: msg)
        asset.broadcast_replace!
      end
    end

    bulk_upload.derive_status!
    Rails.logger.info("PollBulkBedrockIngestionJob: BulkUpload##{bulk_upload.id} → #{status} (#{syncing_assets.size} assets)")

    track_embed_usage(syncing_assets) if status == "COMPLETE" && syncing_assets.any?
  end

  def track_embed_usage(assets)
    sources = assets.filter_map do |asset|
      next if asset.chunks_s3_prefix.blank?

      {
        "filename"         => asset.filename,
        "chunks_s3_prefix" => asset.chunks_s3_prefix
      }
    end
    return if sources.empty?

    TrackIngestionUsageJob.perform_later(embed_chunk_sources: sources)
  end

  def upsert_kb_document(asset)
    return nil if asset.s3_key.blank?

    kb_doc = KbDocument.find_or_initialize_by(s3_key: asset.s3_key)
    kb_doc.display_name = asset.canonical_name.presence || kb_doc.display_name.presence || asset.filename

    kb_doc.aliases = (Array(kb_doc.aliases) + Array(asset.aliases))
                       .map { |a| a.to_s.strip }
                       .compact_blank
                       .reject { |a| a.casecmp?(kb_doc.display_name.to_s) }
                       .uniq
                       .first(15)
    kb_doc.save!
    KbDocumentThumbnailFromS3.call(kb_doc) if image_asset?(asset)
    kb_doc
  rescue StandardError => e
    Rails.logger.warn("PollBulkBedrockIngestionJob: upsert_kb_document failed for asset #{asset.id} — #{e.message}")
    nil
  end

  IMAGE_CONTENT_TYPES = %w[image/jpeg image/jpg image/png image/webp image/gif].freeze
  IMAGE_EXTENSIONS    = %w[.jpg .jpeg .png .webp .gif].freeze

  def image_asset?(asset)
    IMAGE_CONTENT_TYPES.include?(asset.content_type.to_s) ||
      IMAGE_EXTENSIONS.include?(File.extname(asset.s3_key.to_s).downcase)
  end

  def mark_timed_out(bulk_upload, job_id)
    msg = "Bedrock ingestion timed out after #{HARD_TIMEOUT / 60}min"
    bulk_upload.bulk_upload_assets.where(status: "syncing").find_each do |asset|
      asset.update_columns(status: "failed", error_message: msg)
      asset.broadcast_replace!
    end
    bulk_upload.derive_status!
    Rails.logger.warn("PollBulkBedrockIngestionJob: #{msg} for BulkUpload##{bulk_upload.id} job=#{job_id}")
  end
end
