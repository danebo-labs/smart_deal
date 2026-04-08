# frozen_string_literal: true

class TechnicianDocument < ApplicationRecord
  MAX_PER_TECHNICIAN = 20

  validates :identifier, :canonical_name, :channel, presence: true
  validates :canonical_name, uniqueness: { scope: [ :identifier, :channel ] }

  scope :for_identifier, ->(identifier, channel) { where(identifier: identifier, channel: channel) }
  scope :recent,         -> { order(last_used_at: :desc) }

  # Upserts a document record from entity metadata.
  # Increments interaction_count and refreshes last_used_at on every call.
  # Evicts oldest records beyond MAX_PER_TECHNICIAN after each upsert.
  def self.upsert_from_entity(identifier:, channel:, canonical_name:, metadata: {})
    record = find_or_initialize_by(identifier: identifier, channel: channel, canonical_name: canonical_name)
    record.aliases              = (record.aliases + Array(metadata["aliases"])).uniq.first(15)
    record.wa_filename          = metadata["wa_filename"]          if metadata["wa_filename"].present?
    record.source_uri           = metadata["source_uri"]           if metadata["source_uri"].present?
    record.doc_type             = metadata["doc_type"]             if metadata["doc_type"].present?
    record.first_answer_summary = metadata["first_answer_summary"] if metadata["first_answer_summary"].present?
    record.interaction_count = record.new_record? ? 1 : record.interaction_count + 1
    record.last_used_at      = Time.current
    record.save!
    evict_oldest(identifier, channel)
    record
  end

  def self.evict_oldest(identifier, channel)
    records = for_identifier(identifier, channel).recent
    records.offset(MAX_PER_TECHNICIAN).destroy_all
  end

  def self.recent_for(identifier, channel, limit: 5)
    for_identifier(identifier, channel).recent.limit(limit)
  end
end
