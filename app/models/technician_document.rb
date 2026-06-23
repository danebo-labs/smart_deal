# frozen_string_literal: true

class TechnicianDocument < ApplicationRecord
  MAX_PER_TECHNICIAN = 20

  belongs_to :account, optional: true

  validates :identifier, :canonical_name, :channel, presence: true
  validates :canonical_name, uniqueness: { case_sensitive: false, scope: :account_id }

  # Test-only: pre-tenancy callers omit account_id. Mirrors ConversationSession/KbDocument fallback.
  before_validation { self.account_id ||= Account.minimum(:id) } if Rails.env.test?

  # Audit/routing scopes — identifier+channel are preserved but no longer drive deduplication.
  scope :for_identifier, ->(identifier, channel) { where(identifier: identifier, channel: channel) }
  scope :recent,         -> { order(last_used_at: :desc) }

  # Upserts a document record from entity metadata.
  #
  # Deduplication priority (physical identity first, name second):
  #   1. source_uri  — S3 key is the physical document identity, alias-independent.
  #                    "BIMORE brake component" and "Elevator brake assembly unit"
  #                    are the same record when they share the same S3 file.
  #   2. canonical_name (case-insensitive) — fallback when source_uri is blank
  #                    (Bedrock returned 0 citations, backfill didn't run).
  #   3. New record  — only when neither lookup matches.
  #
  # Increments interaction_count and refreshes last_used_at on every call.
  # Evicts oldest records beyond MAX_PER_TECHNICIAN after each upsert.
  def self.upsert_from_entity(identifier:, channel:, canonical_name:, metadata: {}, account_id: nil)
    normalized  = canonical_name.to_s.strip
    source_uri  = metadata["source_uri"].to_s.presence
    scope = account_id ? where(account_id: account_id) : all

    record = (source_uri && scope.find_by(source_uri: source_uri)) ||
             scope.find_by("LOWER(canonical_name) = LOWER(?)", normalized) ||
             new(identifier: identifier, channel: channel, canonical_name: normalized, account_id: account_id)

    apply_metadata(record, metadata, account_id: account_id)
  rescue ActiveRecord::RecordNotUnique
    record = scope.find_by(source_uri: source_uri) if source_uri
    record ||= scope.find_by("LOWER(canonical_name) = LOWER(?)", normalized)
    return record unless record
    record.interaction_count += 1
    record.last_used_at = Time.current
    record.save!
    record
  end

  def self.apply_metadata(record, metadata, account_id: nil)
    record.aliases              = (record.aliases + Array(metadata["aliases"])).uniq.first(15)
    record.wa_filename          = metadata["wa_filename"]          if metadata["wa_filename"].present?
    record.source_uri           = metadata["source_uri"]           if metadata["source_uri"].present?
    record.doc_type             = metadata["doc_type"]             if metadata["doc_type"].present?
    record.first_answer_summary = metadata["first_answer_summary"] if metadata["first_answer_summary"].present?
    record.interaction_count = record.new_record? ? 1 : record.interaction_count + 1
    record.last_used_at      = Time.current
    record.save!
    evict_oldest(account_id: account_id)
    record
  end
  private_class_method :apply_metadata

  # Evicts oldest records beyond MAX_PER_TECHNICIAN, scoped to account when provided.
  def self.evict_oldest(account_id: nil)
    scope = account_id ? where(account_id: account_id) : all
    scope.recent.offset(MAX_PER_TECHNICIAN).destroy_all
  end

  # Audit helper — returns documents scoped to a specific identifier+channel.
  def self.recent_for(identifier, channel, limit: 5)
    for_identifier(identifier, channel).recent.limit(limit)
  end
end
