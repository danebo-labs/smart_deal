# frozen_string_literal: true

class ProcessBulkUploadJob < ApplicationJob
  queue_as :bulk_ingestion
  discard_on ActiveRecord::RecordNotFound

  # @param bulk_upload_id [Integer]
  # @param zip_path       [String] absolute path to the ZIP file on disk
  def perform(bulk_upload_id, zip_path)
    bulk_upload = BulkUpload.find(bulk_upload_id)

    BatchIngestionService.new.process!(bulk_upload, zip_path)
    SubmitClaudeBatchJob.perform_later(bulk_upload_id)
  rescue ZipExtractionService::Error => e
    mark_failed(bulk_upload_id, e.message)
    Rails.logger.error("ProcessBulkUploadJob[#{bulk_upload_id}] ZIP error: #{e.message}")
  rescue StandardError => e
    mark_failed(bulk_upload_id, e.message)
    Rails.logger.error("ProcessBulkUploadJob[#{bulk_upload_id}] failed: #{e.message}")
    raise
  end

  private

  def mark_failed(bulk_upload_id, message)
    BulkUpload.where(id: bulk_upload_id).update_all(status: "failed", error_message: message)
    # Catch any non-terminal assets — assets are created as "uploaded_s3" (not "pending")
    # so we exclude all terminal statuses rather than targeting a specific in-progress one.
    BulkUploadAsset
      .joins(:bulk_upload).where(bulk_uploads: { id: bulk_upload_id })
      .where.not(status: %w[complete failed])
      .update_all(status: "failed", error_message: message)
  end
end
