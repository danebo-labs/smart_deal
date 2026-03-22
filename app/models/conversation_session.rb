# frozen_string_literal: true

class ConversationSession < ApplicationRecord
  EXPIRY_MINUTES = 30
  MAX_HISTORY    = 20
  MAX_ENTITIES   = 5

  CHANNELS = %w[whatsapp web].freeze

  belongs_to :user, optional: true

  validates :identifier, presence: true
  validates :channel,    inclusion: { in: CHANNELS }
  validates :expires_at, presence: true

  scope :active,   -> { where("expires_at > ?", Time.current) }
  scope :expired,  -> { where(expires_at: ..Time.current) }
  scope :whatsapp, -> { where(channel: "whatsapp") }
  scope :web,      -> { where(channel: "web") }

  # ─── Lifecycle ──────────────────────────────────────────────────────────────

  def self.find_or_create_for(identifier:, channel: "whatsapp", user_id: nil)
    record = find_by(identifier: identifier, channel: channel)

    if record.nil? || record.expired?
      record&.destroy
      record = create!(
        identifier:  identifier,
        channel:     channel,
        user_id:     user_id,
        expires_at:  EXPIRY_MINUTES.minutes.from_now
      )
    end

    record
  end

  def expired?
    expires_at <= Time.current
  end

  def refresh!
    update!(expires_at: EXPIRY_MINUTES.minutes.from_now)
  end

  def reset_procedure!
    update!(current_procedure: {}, session_status: "active")
  end

  # ─── History ────────────────────────────────────────────────────────────────

  def add_to_history(role, content)
    history = conversation_history.last(MAX_HISTORY - 1)
    history << { "role" => role, "content" => content, "ts" => Time.current.iso8601 }
    update!(conversation_history: history)
  end

  def history_for_prompt
    conversation_history.map { |m| { role: m["role"], content: m["content"] } }
  end

  # ─── Entities ───────────────────────────────────────────────────────────────

  def add_entity(name, context_chunks)
    return false if active_entities.size >= MAX_ENTITIES

    entities = active_entities.merge(
      name => { "chunks" => context_chunks, "added_at" => Time.current.iso8601 }
    )
    update!(active_entities: entities)
    true
  end

  def entity_count
    active_entities.size
  end
end
