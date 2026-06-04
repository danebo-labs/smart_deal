# frozen_string_literal: true

class SubmitClaudeBatchJob < ApplicationJob
  queue_as :bulk_ingestion
  discard_on ActiveRecord::RecordNotFound

  # @param bulk_upload_id [Integer]
  def perform(bulk_upload_id)
    bulk_upload = BulkUpload.find(bulk_upload_id)

    batch = BatchIngestionService.new.submit!(bulk_upload)
    return unless batch  # safety: no uploaded_s3 assets — nothing to poll

    PollClaudeBatchJob.set(wait: 30.seconds).perform_later(
      bulk_upload_id,
      started_at_iso: Time.current.iso8601
    )
  rescue StandardError => e
    mark_failed(bulk_upload_id, e.message)
    Rails.logger.error("SubmitClaudeBatchJob[#{bulk_upload_id}] failed: #{e.message}")
    raise
  end

  private

  def mark_failed(bulk_upload_id, message)
    BulkUpload.where(id: bulk_upload_id).update_all(status: "failed", error_message: message)
    BulkUploadAsset
      .joins(:bulk_upload).where(bulk_uploads: { id: bulk_upload_id })
      .where(status: %w[uploaded_s3 in_batch])
      .update_all(status: "failed", error_message: message)
  end
end
