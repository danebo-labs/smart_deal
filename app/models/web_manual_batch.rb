# frozen_string_literal: true

class WebManualBatch < ApplicationRecord
  STATUSES = %w[pending submitting submitted submission_unknown in_progress parsing parsed syncing complete failed].freeze
  URGENT_STATUSES = %w[pending processing syncing complete failed skipped].freeze

  belongs_to :kb_document, optional: true
  belongs_to :conv_session, class_name: "ConversationSession", optional: true
  belongs_to :account

  validates :s3_key, :filename, :sha256, :ingestion_contract_version, presence: true

  # Test-only: pre-tenancy callers omit account_id. Mirrors ConversationSession/KbDocument fallback.
  before_validation { self.account_id ||= Account.minimum(:id) } if Rails.env.test?
  validates :status, inclusion: { in: STATUSES }
  validates :urgent_status, inclusion: { in: URGENT_STATUSES }, allow_blank: true
  validates :sha256, uniqueness: { scope: [ :account_id, :s3_key, :ingestion_contract_version ] }
  validates :claude_batch_id, uniqueness: true, allow_blank: true

  scope :active, -> { where(status: %w[pending submitted in_progress parsing parsed syncing]) }

  def self.statuses
    STATUSES.index_with(&:itself)
  end

  def terminal?
    complete? || failed?
  end

  def complete?
    status == "complete"
  end

  def failed?
    status == "failed"
  end

  def submitted_for_polling?
    claude_batch_id.present? && %w[submitted in_progress].include?(status)
  end
end
