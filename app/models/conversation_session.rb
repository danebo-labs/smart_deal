# frozen_string_literal: true

class ConversationSession < ApplicationRecord
  EXPIRY_MINUTES = 30
  MAX_HISTORY    = 20
  MAX_ENTITIES   = ENV.fetch('SESSION_MAX_ENTITIES', 10).to_i
  MAX_MSG_LENGTH = 300

  CHANNELS = %w[whatsapp web shared].freeze

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
    if SharedSession::ENABLED
      identifier = SharedSession::IDENTIFIER
      channel    = SharedSession::CHANNEL
    end
    record = find_by(identifier: identifier, channel: channel)

    if record.nil? || record.expired?
      record&.destroy
      record = create!(
        identifier:  identifier,
        channel:     channel,
        user_id:     user_id,
        expires_at:  EXPIRY_MINUTES.minutes.from_now
      )
      preload_recent_entities(record)
    end

    record
  end

  def self.preload_recent_entities(session)
    TechnicianDocument.recent.limit(MAX_ENTITIES).each do |td|
      session.add_entity_with_aliases(td.canonical_name, td.aliases, {
        "source"               => "technician_memory",
        "wa_filename"          => td.wa_filename,
        "source_uri"           => td.source_uri,
        "doc_type"             => td.doc_type,
        "first_answer_summary" => td.first_answer_summary,
        "extraction_method"    => "preloaded_from_history"
      })
    end
  rescue StandardError => e
    Rails.logger.warn("ConversationSession: preload_recent_entities failed: #{e.message}")
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
    history << { "role" => role, "content" => content.to_s.truncate(MAX_MSG_LENGTH), "ts" => Time.current.iso8601 }
    update!(conversation_history: history)
  end

  def history_for_prompt
    conversation_history.map { |m| { role: m["role"], content: m["content"] } }
  end

  def recent_history_for_prompt(turns: 3)
    conversation_history.last(turns).map { |m| { role: m["role"], content: m["content"] } }
  end

  # ─── Entities ───────────────────────────────────────────────────────────────

  # Stores metadata-only (no chunks). FIFO eviction when count exceeds MAX_ENTITIES.
  # Deduplicates: if name already matches any existing entity (by canonical key,
  # wa_filename, or any alias), the existing record is kept unchanged.
  def add_entity(name, metadata = {})
    return true if find_entity_by_name_or_alias(name)

    entities = active_entities.dup
    entities[name] = metadata.merge("added_at" => Time.current.iso8601)
    evict_oldest!(entities)
    update!(active_entities: entities)
    true
  end

  # Registers a named entity with its full alias set.
  # If any of canonical_name or any alias already matches an existing entity,
  # merges the new aliases into it instead of creating a duplicate.
  # @param canonical_name [String]  human-readable document name (key in hash)
  # @param aliases [Array<String>]  all known aliases (semantic + technical + wa_filename)
  # @param metadata [Hash]
  def add_entity_with_aliases(canonical_name, aliases = [], metadata = {})
    entities = active_entities.dup

    existing_key = find_entity_by_name_or_alias(canonical_name) ||
                   aliases.lazy.filter_map { |a| find_entity_by_name_or_alias(a) }.first

    if existing_key
      existing = entities[existing_key].dup
      merged   = sanitize_aliases(((existing["aliases"] || []) + aliases).map(&:to_s))
      entities[existing_key] = existing.merge("aliases" => merged)
    else
      entities[canonical_name] = metadata.merge(
        "canonical_name" => canonical_name,
        "aliases"        => sanitize_aliases(aliases.map(&:to_s)),
        "added_at"       => Time.current.iso8601
      )
      evict_oldest!(entities)
    end

    update!(active_entities: entities)
    true
  end

  # Physical-identity lookup: returns the canonical key whose entity has the
  # given source_uri. Used to dedup entities across aliases — two different
  # canonical_names with the same s3_uri are the same physical document.
  # @return [String, nil]
  def find_entity_by_source_uri(uri)
    return nil if uri.blank?
    active_entities.each do |key, meta|
      return key if meta["source_uri"].to_s == uri.to_s
    end
    nil
  end

  # Case-insensitive lookup across canonical keys, wa_filename, and aliases.
  # @return [String, nil] the canonical key if found
  def find_entity_by_name_or_alias(name)
    return nil if name.blank?

    term = name.to_s.strip
    active_entities.each_key do |key|
      next unless key.casecmp?(term) ||
                  active_entities[key]["wa_filename"].to_s.casecmp?(term) ||
                  Array(active_entities[key]["aliases"]).any? { |a| a.to_s.casecmp?(term) }

      return key
    end
    nil
  end

  def has_active_entities?
    active_entities.present?
  end

  def active_document_names
    active_entities.keys
  end

  def entity_count
    active_entities.size
  end

  private

  def sanitize_aliases(aliases_array)
    seen   = {}
    result = []

    aliases_array.each do |raw|
      s = raw.to_s.strip
      next if s.length < 2 || s.length > 60
      next if s.start_with?("|")
      next if s.include?("|")
      next if s.include?("**")
      next if s.include?("##")
      next if s.include?("⚠️")
      next if s.include?("→")
      next if s.include?("←")
      next if s.include?("http://")
      next if s.include?("https://")
      next if s.include?("s3://")
      next if s.count(" ") > 8

      key = s.downcase
      next if seen[key]

      seen[key] = true
      result << s
      break if result.size >= 15
    end

    result
  end

  def evict_oldest!(entities)
    return unless entities.size > MAX_ENTITIES

    oldest_key = entities.min_by { |_, v| v["added_at"].to_s }.first
    entities.delete(oldest_key)
  end
end
