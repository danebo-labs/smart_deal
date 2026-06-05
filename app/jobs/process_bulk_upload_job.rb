# frozen_string_literal: true

class ProcessBulkUploadJob < ApplicationJob
  queue_as :bulk_ingestion
  discard_on ActiveRecord::RecordNotFound

  # @param bulk_upload_id [Integer]
  # @param archive_key    [String] temporary S3 key for the uploaded ZIP
  # @param upload_locale  [String, nil] UI locale from upload request (session). Not named
  #                       +locale+ — ActiveJob reserves that for job-level I18n.
  def perform(bulk_upload_id, archive_key, upload_locale = nil)
    I18n.with_locale(normalize_locale(upload_locale)) do
      perform_with_locale(bulk_upload_id, archive_key)
    end
  end

  private

  def perform_with_locale(bulk_upload_id, archive_key)
    bulk_upload = BulkUpload.find(bulk_upload_id)

    archive_service = BulkUploadArchiveService.new
    begin
      archive_service.with_downloaded(archive_key) do |zip_path|
        BatchIngestionService.new.process!(bulk_upload, zip_path)
      end
    ensure
      archive_service.delete(archive_key)
    end

    if bulk_upload.bulk_upload_assets.exists?(status: "uploaded_s3")
      SubmitClaudeBatchJob.perform_later(bulk_upload_id)
    elsif bulk_upload.bulk_upload_assets.exists?(status: "failed")
      bulk_upload.update!(status: "failed", error_message: I18n.t("bulk_uploads.no_uploadable_files"))
    else
      bulk_upload.update!(status: "failed", error_message: I18n.t("bulk_uploads.empty_zip"))
    end
  rescue ZipExtractionService::Error => e
    mark_failed(bulk_upload_id, e.message)
    Rails.logger.error("ProcessBulkUploadJob[#{bulk_upload_id}] ZIP error: #{e.message}")
  rescue StandardError => e
    # Terminal: the archive is deleted in ensure, so recovery requires a new upload.
    mark_failed(bulk_upload_id, e.message)
    Rails.logger.error("ProcessBulkUploadJob[#{bulk_upload_id}] failed: #{e.message}")
  end

  def normalize_locale(upload_locale)
    sym = upload_locale.to_s.presence&.to_sym
    LocaleSwitchable::ALLOWED_LOCALES.include?(sym) ? sym : I18n.default_locale
  end

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
