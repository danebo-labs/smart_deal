# frozen_string_literal: true

class BulkUploadAsset < ApplicationRecord
  belongs_to :bulk_upload
  belongs_to :kb_document, optional: true

  STATUSES = %w[pending uploaded_s3 in_batch parsed syncing complete failed].freeze
  INGESTION_CONTENT_DEDUP = "content_dedup"

  validates :custom_id, presence: true, uniqueness: true
  validates :sha256, presence: true
  validates :filename, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :complete,  -> { where(status: "complete") }
  scope :failed,    -> { where(status: "failed") }
  scope :syncing,   -> { where(status: "syncing") }
  scope :in_batch,  -> { where(status: "in_batch") }

  # Returns all custom_ids associated with this asset — the primary custom_id
  # plus any per-page ids written during cost_v2 batch submission.
  def all_custom_ids
    ([ custom_id ] + Array(batch_custom_ids)).uniq
  end

  # Contract-versioned idempotency key: same bytes under a NEW ingestion contract
  # must produce a new asset row (and re-parse) instead of colliding with — or
  # dedup-hitting — chunks produced under an older contract.
  def self.custom_id_for(binary, contract_version:)
    custom_id_for_sha(Digest::SHA256.hexdigest(binary), contract_version: contract_version)
  end

  def self.custom_id_for_sha(sha256, contract_version:)
    Digest::SHA256.hexdigest("#{sha256}:#{contract_version}")[0..31]
  end

  def display_name
    canonical_name.presence || filename
  end

  def content_deduped?
    status == "complete" && ingestion_path == INGESTION_CONTENT_DEDUP
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
