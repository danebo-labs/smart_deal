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

  # ACK <100 ms: validate + sha256 + find_or_create BulkUpload + enqueue + redirect.
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
        zip_path = persist_zip(zip_param.tempfile.path, sha256)
        reenqueue_failed_upload!(bulk_upload, zip_path)
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
    bulk_upload.save!

    zip_path = persist_zip(zip_param.tempfile.path, sha256)
    ProcessBulkUploadJob.perform_later(bulk_upload.id, zip_path)

    redirect_to bulk_upload_path(bulk_upload)
  end


  private

  def reenqueue_failed_upload!(bulk_upload, zip_path)
    bulk_upload.bulk_upload_assets.delete_all
    bulk_upload.update!(
      status:                  "pending",
      error_message:           nil,
      claude_batch_id:         nil,
      bedrock_ingestion_job_id: nil,
      asset_count:             0
    )
    ProcessBulkUploadJob.perform_later(bulk_upload.id, zip_path)
  end

  def persist_zip(tempfile_path, sha256)
    dir  = Rails.root.join("tmp/bulk_uploads")
    FileUtils.mkdir_p(dir)
    dest = dir.join("#{sha256}.zip").to_s
    FileUtils.cp(tempfile_path, dest) unless File.exist?(dest)
    dest
  end

  def not_found
    render plain: "Not found", status: :not_found
  end
end
