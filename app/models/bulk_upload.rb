# frozen_string_literal: true

class BulkUpload < ApplicationRecord
  belongs_to :user, optional: true
  has_many :bulk_upload_assets, dependent: :destroy

  STATUSES = %w[pending processing complete failed].freeze

  validates :sha256, presence: true, uniqueness: true
  validates :original_filename, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :processing, -> { where(status: "processing") }
  scope :complete,   -> { where(status: "complete") }
  scope :failed,     -> { where(status: "failed") }

  def processing_batch_ids
    Array(claude_batch_ids).presence || Array(claude_batch_id).compact
  end

  def derive_status!
    counts    = bulk_upload_assets.group(:status).count
    total     = counts.values.sum
    n_complete = counts["complete"].to_i
    n_failed   = counts["failed"].to_i
    n_in_progress = counts.except("failed", "complete").values.sum

    new_status = if total.zero?
      "pending"
    elsif n_complete == total
      "complete"
    elsif n_in_progress == 0 && n_complete > 0
      # partial success: some complete, rest failed/skipped, nothing in flight
      "complete"
    elsif n_in_progress == 0 && n_complete == 0
      "failed"
    else
      "processing"
    end

    return if new_status == status

    if new_status == "complete" && n_failed > 0
      summary = I18n.t("bulk_uploads.partial_complete", complete: n_complete, failed: n_failed)
      update_columns(status: new_status, error_message: summary)
    else
      update_column(:status, new_status)
    end
  end
end
