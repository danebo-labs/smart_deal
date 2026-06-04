# frozen_string_literal: true

class ProcessBulkUploadJob < ApplicationJob
  queue_as :bulk_ingestion
  discard_on ActiveRecord::RecordNotFound

  # @param bulk_upload_id [Integer]
  # @param zip_path       [String] absolute path to the ZIP file on disk
  # @param upload_locale  [String, nil] UI locale from upload request (session). Not named
  #                       +locale+ — ActiveJob reserves that for job-level I18n.
  def perform(bulk_upload_id, zip_path, upload_locale = nil)
    I18n.with_locale(normalize_locale(upload_locale)) do
      perform_with_locale(bulk_upload_id, zip_path)
    end
  end

  private

  def perform_with_locale(bulk_upload_id, zip_path)
    bulk_upload = BulkUpload.find(bulk_upload_id)

    BatchIngestionService.new.process!(bulk_upload, zip_path)

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
    mark_failed(bulk_upload_id, e.message)
    Rails.logger.error("ProcessBulkUploadJob[#{bulk_upload_id}] failed: #{e.message}")
    raise
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
