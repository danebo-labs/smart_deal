# frozen_string_literal: true

class BulkUploadsController < ApplicationController
  include AuthenticationConcern

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def show
    @bulk_upload = BulkUpload.includes(:bulk_upload_assets).find(params[:id])
  end
  def new
    @bulk_upload = BulkUpload.new
  end

  # Validate, deduplicate, stage the ZIP in S3, enqueue processing, and redirect.
  def create
    zip_param = params[:zip_file]

    if zip_param.blank?
      flash[:alert] = t("bulk_uploads.select_zip")
      redirect_to new_bulk_upload_path and return
    end

    sha256 = Digest::SHA256.file(zip_param.tempfile.path).hexdigest

    bulk_upload = BulkUpload.find_or_initialize_by(sha256: sha256)
    if bulk_upload.persisted?
      if bulk_upload.status == "failed"
        archive_key = persist_zip(zip_param.tempfile.path, sha256)
        reenqueue_failed_upload!(bulk_upload, archive_key)
        flash[:notice] = t("bulk_uploads.retry_enqueued")
      elsif bulk_upload.status == "complete"
        flash[:notice] = t("bulk_uploads.already_complete")
      else
        flash[:notice] = t("bulk_uploads.already_in_progress")
      end
      redirect_to bulk_upload_path(bulk_upload) and return
    end

    bulk_upload.assign_attributes(
      original_filename: zip_param.original_filename,
      status:            "pending",
      asset_count:       0,
      user:              current_user
    )
    archive_key = persist_zip(zip_param.tempfile.path, sha256)
    bulk_upload.save!

    ProcessBulkUploadJob.perform_later(bulk_upload.id, archive_key, I18n.locale.to_s)

    redirect_to bulk_upload_path(bulk_upload)
  end


  private

  def reenqueue_failed_upload!(bulk_upload, archive_key)
    bulk_upload.bulk_upload_assets.delete_all
    bulk_upload.update!(
      status:                  "pending",
      error_message:           nil,
      claude_batch_id:         nil,
      claude_batch_ids:        [],
      bedrock_ingestion_job_id: nil,
      asset_count:             0
    )
    ProcessBulkUploadJob.perform_later(bulk_upload.id, archive_key, I18n.locale.to_s)
  end

  def persist_zip(tempfile_path, sha256)
    BulkUploadArchiveService.new.upload(local_path: tempfile_path, sha256: sha256)
  end

  def not_found
    render plain: "Not found", status: :not_found
  end
end
