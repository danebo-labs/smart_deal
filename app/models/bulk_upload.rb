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

  def derive_status!
    counts = bulk_upload_assets.group(:status).count
    total  = counts.values.sum

    new_status = if total.zero?
      "pending"
    elsif counts["complete"].to_i == total
      "complete"
    elsif counts["failed"].to_i > 0 && counts.except("failed", "complete").values.sum == 0
      "failed"
    else
      "processing"
    end

    update_column(:status, new_status) if new_status != status
  end
end
