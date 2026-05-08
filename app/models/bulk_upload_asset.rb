# frozen_string_literal: true

class BulkUploadAsset < ApplicationRecord
  belongs_to :bulk_upload
  belongs_to :kb_document, optional: true

  STATUSES = %w[pending uploaded_s3 in_batch parsed syncing complete failed].freeze

  validates :custom_id, presence: true, uniqueness: true
  validates :sha256, presence: true
  validates :filename, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :complete,  -> { where(status: "complete") }
  scope :failed,    -> { where(status: "failed") }
  scope :syncing,   -> { where(status: "syncing") }
  scope :in_batch,  -> { where(status: "in_batch") }

  # SHA-256 of raw binary truncated to 32 hex chars — stable cross-upload idempotency key.
  def self.custom_id_for(binary)
    Digest::SHA256.hexdigest(binary)[0..31]
  end

  def display_name
    canonical_name.presence || filename
  end

  # Called for status transitions on an already-visible asset row.
  def broadcast_replace!
    broadcast_replace_to(
      "bulk_upload_#{bulk_upload_id}",
      target: "asset_#{id}",
      partial: "bulk_uploads/asset",
      locals: { asset: self }
    )
  end

  # Called when an asset is first created so it appears immediately in the UI.
  # Removes the "Preparando archivos…" placeholder on first append.
  def broadcast_append!
    broadcast_remove_to("bulk_upload_#{bulk_upload_id}", target: "assets-empty")
    broadcast_append_to(
      "bulk_upload_#{bulk_upload_id}",
      target: "assets-list",
      partial: "bulk_uploads/asset",
      locals: { asset: self }
    )
  end
end
