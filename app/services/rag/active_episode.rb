# frozen_string_literal: true

module Rag
  # Parsed, bounded view of conversation_sessions.active_episode.
  # A blank episode is {}. Invalid or expired payloads become blank and never raise.
  class ActiveEpisode
    FACT_KEYS = %w[manufacturer model fault_code].freeze
    STATUSES = %w[known unknown_confirmed absent_confirmed].freeze
    SOURCES = %w[user photo].freeze
    PENDING_SUBJECTS = %w[manufacturer model fault_code].freeze
    UNKNOWN_CONFIRMED_KEYS = %w[manufacturer model].freeze
    ABSENT_CONFIRMED_KEYS = %w[fault_code].freeze
    PHOTO_FACT_KEYS = %w[manufacturer model].freeze

    MAX_GOAL_CHARS = 300
    MAX_VALUE_CHARS = 60
    MAX_IDENTIFIERS = 5
    MAX_IDENTIFIER_CHARS = 30
    MAX_CONFLICTS = 3
    MAX_BYTES = 2048

    attr_accessor :episode_id, :status, :opened_at, :updated_at, :opened_by,
                  :goal, :facts, :identifiers, :pending_fact, :active_photo, :conflicts
    attr_reader :reason

    def initialize
      @facts = {}
      @identifiers = []
      @conflicts = []
      @status = "active"
    end

    def self.parse(raw, now: Time.current)
      episode = new
      data = coerce(raw)
      if data == :invalid
        episode.mark("invalid_state")
        return episode
      end
      return episode if data.blank?
      unless data["v"].to_i == 1 && data["episode_id"].present?
        episode.mark("invalid_state")
        return episode
      end

      updated = parse_time(data["updated_at"])
      if updated.nil? || updated < now - ConversationSession::EPISODE_WINDOW
        episode.mark("expired")
        return episode
      end

      episode.episode_id = data["episode_id"].to_s
      episode.status = data["status"].to_s.presence || "active"
      episode.opened_at = data["opened_at"].to_s
      episode.updated_at = data["updated_at"].to_s
      episode.opened_by = data["opened_by"].to_s.presence
      episode.goal = sanitize_goal(data["goal"])
      episode.facts = sanitize_facts(data["facts"])
      episode.identifiers = sanitize_identifiers(data["identifiers"])
      episode.pending_fact = sanitize_pending(data["pending_fact"])
      episode.active_photo = sanitize_photo(data["active_photo"])
      episode.conflicts = sanitize_conflicts(data["conflicts"])
      episode
    end

    def self.open(correlation_id:, now:)
      episode = new
      episode.episode_id = "ep_#{SecureRandom.hex(8)}"
      episode.status = "active"
      episode.opened_at = now.iso8601
      episode.updated_at = now.iso8601
      episode.opened_by = correlation_id.to_s.presence
      episode
    end

    def blank?
      episode_id.to_s.empty?
    end

    def fork
      copy = self.class.new
      return copy if blank?

      copy.episode_id = episode_id
      copy.status = status
      copy.opened_at = opened_at
      copy.updated_at = updated_at
      copy.opened_by = opened_by
      copy.goal = goal&.deep_dup
      copy.facts = facts.deep_dup
      copy.identifiers = identifiers.deep_dup
      copy.pending_fact = pending_fact&.deep_dup
      copy.active_photo = active_photo&.deep_dup
      copy.conflicts = conflicts.deep_dup
      copy
    end

    def touch!(now)
      self.updated_at = now.iso8601
    end

    def assign_goal!(text, correlation_id:)
      stripped = text.to_s.strip
      self.goal = {
        "text" => stripped.first(MAX_GOAL_CHARS),
        "correlation_id" => correlation_id.to_s,
        "truncated" => stripped.length > MAX_GOAL_CHARS
      }
    end

    def goal_truncated?
      goal&.fetch("truncated", false) == true
    end

    def clear_goal!
      self.goal = nil
    end

    def write_fact!(key, status:, value: nil, source: "user", correlation_id:, at:)
      fact = {
        "status" => status,
        "source" => source,
        "correlation_id" => correlation_id.to_s,
        "at" => at
      }
      fact["value"] = value.to_s.squish.first(MAX_VALUE_CHARS) if status == "known"
      facts[key.to_s] = fact
    end

    def clear_fact!(key)
      facts.delete(key.to_s)
    end

    def fact(key)
      facts[key.to_s]
    end

    def clear_pending!
      self.pending_fact = nil
    end

    def clear_identifiers!
      self.identifiers = []
    end

    def clear_conflicts_for!(fact_key)
      conflicts.reject! { |row| row["fact"] == fact_key.to_s }
    end

    def append_identifier!(value, correlation_id:, source: "user")
      literal = value.to_s.squish.first(MAX_IDENTIFIER_CHARS)
      return if literal.blank?

      label = FollowupQueryRewriter.normalize_label(literal)
      return if identifiers.any? { |item| FollowupQueryRewriter.normalize_label(item["value"]) == label }

      identifiers << { "value" => literal, "source" => source, "correlation_id" => correlation_id.to_s }
      identifiers.shift while identifiers.size > MAX_IDENTIFIERS
    end

    def add_conflict!(fact:, user:, photo:, correlation_id:)
      conflicts.reject! { |row| row["fact"] == fact.to_s }
      conflicts << {
        "fact" => fact.to_s,
        "user" => user.to_s,
        "photo" => photo.to_s,
        "correlation_id" => correlation_id.to_s
      }
      conflicts.shift while conflicts.size > MAX_CONFLICTS
    end

    def to_h
      return {} if blank?

      payload = {
        "v" => 1,
        "episode_id" => episode_id,
        "status" => status.presence || "active",
        "opened_at" => opened_at,
        "updated_at" => updated_at,
        "opened_by" => opened_by,
        "goal" => goal,
        "facts" => facts,
        "identifiers" => identifiers,
        "pending_fact" => pending_fact,
        "active_photo" => active_photo,
        "conflicts" => conflicts
      }
      payload.compact!
      shrink_to_budget!(payload)
      payload
    end

    def self.coerce(raw)
      case raw
      when nil then {}
      when Hash then raw.deep_stringify_keys
      when String
        return {} if raw.strip.empty?

        parsed = JSON.parse(raw)
        return :invalid unless parsed.is_a?(Hash)

        parsed.deep_stringify_keys
      else
        :invalid
      end
    rescue JSON::ParserError, TypeError
      :invalid
    end
    private_class_method :coerce

    def self.parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end
    private_class_method :parse_time

    def self.sanitize_goal(raw)
      return nil unless raw.is_a?(Hash)

      text = raw["text"].to_s
      return nil if text.blank?

      {
        "text" => text.first(MAX_GOAL_CHARS),
        "correlation_id" => raw["correlation_id"].to_s,
        "truncated" => raw["truncated"] == true || text.length > MAX_GOAL_CHARS
      }
    end
    private_class_method :sanitize_goal

    def self.sanitize_facts(raw)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, fact), kept|
        key = key.to_s
        next unless FACT_KEYS.include?(key)
        next unless fact.is_a?(Hash)

        fact = fact.stringify_keys
        status = fact["status"].to_s
        source = fact["source"].to_s
        next unless STATUSES.include?(status) && SOURCES.include?(source)
        next if status == "unknown_confirmed" && UNKNOWN_CONFIRMED_KEYS.exclude?(key)
        next if status == "absent_confirmed" && ABSENT_CONFIRMED_KEYS.exclude?(key)
        next if source == "photo" && PHOTO_FACT_KEYS.exclude?(key)

        cleaned = {
          "status" => status,
          "source" => source,
          "correlation_id" => fact["correlation_id"].to_s,
          "at" => fact["at"].to_s
        }
        if status == "known"
          value = fact["value"].to_s.squish.first(MAX_VALUE_CHARS)
          next if value.blank?

          cleaned["value"] = value
        end
        kept[key] = cleaned
      end
    end
    private_class_method :sanitize_facts

    def self.sanitize_identifiers(raw)
      return [] unless raw.is_a?(Array)

      kept = []
      seen = {}
      raw.each do |item|
        next unless item.is_a?(Hash)

        item = item.stringify_keys
        value = item["value"].to_s.squish.first(MAX_IDENTIFIER_CHARS)
        next if value.blank?

        label = FollowupQueryRewriter.normalize_label(value)
        next if seen[label]

        seen[label] = true
        kept << { "value" => value, "source" => item["source"].to_s.presence || "user", "correlation_id" => item["correlation_id"].to_s }
      end
      kept.last(MAX_IDENTIFIERS)
    end
    private_class_method :sanitize_identifiers

    def self.sanitize_pending(raw)
      return nil unless raw.is_a?(Hash)

      subject = raw["subject"].to_s
      return nil unless PENDING_SUBJECTS.include?(subject)

      { "subject" => subject, "correlation_id" => raw["correlation_id"].to_s }
    end
    private_class_method :sanitize_pending

    def self.sanitize_photo(raw)
      return nil unless raw.is_a?(Hash)

      photo = {}
      photo["field_photo_id"] = raw["field_photo_id"] if raw["field_photo_id"].present?
      photo["sha256"] = raw["sha256"].to_s if raw["sha256"].present?
      photo["correlation_id"] = raw["correlation_id"].to_s if raw["correlation_id"].present?
      photo.presence
    end
    private_class_method :sanitize_photo

    def self.sanitize_conflicts(raw)
      return [] unless raw.is_a?(Array)

      raw.filter_map { |item|
        next unless item.is_a?(Hash)

        item = item.stringify_keys
        fact = item["fact"].to_s
        next unless FACT_KEYS.include?(fact)

        {
          "fact" => fact,
          "user" => item["user"].to_s,
          "photo" => item["photo"].to_s,
          "correlation_id" => item["correlation_id"].to_s
        }
      }.last(MAX_CONFLICTS)
    end
    private_class_method :sanitize_conflicts

    def mark(reason)
      @reason = reason
    end

    def shrink_to_budget!(payload)
      return if json_bytes(payload) <= MAX_BYTES

      payload["conflicts"] = []
      return if json_bytes(payload) <= MAX_BYTES

      identifiers = payload["identifiers"]
      return unless identifiers.is_a?(Array)

      identifiers.shift while identifiers.any? && json_bytes(payload) > MAX_BYTES
    end

    def json_bytes(payload)
      JSON.generate(payload).bytesize
    end
  end
end
