# frozen_string_literal: true

module Rag
  # Parsed, bounded view of conversation_sessions.active_episode.
  # A blank episode is {}. Invalid or expired payloads become blank and never raise.
  class ActiveEpisode
    FACT_KEYS = %w[manufacturer model controller fault_code].freeze
    STATUSES = %w[known unknown_confirmed absent_confirmed].freeze
    SOURCES = %w[user photo catalog].freeze
    PENDING_SUBJECTS = %w[manufacturer model controller fault_code].freeze
    UNKNOWN_CONFIRMED_KEYS = %w[manufacturer model controller].freeze
    ABSENT_CONFIRMED_KEYS = %w[fault_code].freeze
    PHOTO_FACT_KEYS = %w[manufacturer model].freeze

    MAX_GOAL_CHARS = 300
    MAX_VALUE_CHARS = 60
    MAX_IDENTIFIERS = 5
    MAX_IDENTIFIER_CHARS = 30
    MAX_CONFLICTS = 3
    MAX_OBSERVATIONS = 3
    MAX_STORED_OBSERVATIONS = 12
    MAX_OBSERVATION_CHARS = 180
    MAX_CHECKS = 6
    MAX_CHECK_CHARS = 120
    CHECK_STATUSES = %w[done not_done].freeze
    MAX_REJECTED = 4
    REJECTED_SLOTS = %w[manufacturer model controller fault_code identifier].freeze
    MAX_BYTES = 4096

    attr_accessor :episode_id, :status, :opened_at, :updated_at, :opened_by,
                  :goal, :facts, :identifiers, :pending_fact, :pending_question, :active_photo, :conflicts,
                  :observations, :checks, :rejected
    attr_reader :reason

    def initialize
      @facts = {}
      @identifiers = []
      @conflicts = []
      @observations = []
      @checks = []
      @rejected = []
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
      episode.pending_question = PendingQuestion.coerce(data["pending_question"])
      episode.active_photo = sanitize_photo(data["active_photo"])
      episode.conflicts = sanitize_conflicts(data["conflicts"])
      episode.observations = sanitize_observations(data["observations"])
      episode.checks = sanitize_checks(data["checks"])
      episode.rejected = sanitize_rejected(data["rejected"])
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
      copy.pending_question = pending_question&.deep_dup
      copy.active_photo = active_photo&.deep_dup
      copy.conflicts = conflicts.deep_dup
      copy.observations = observations.deep_dup
      copy.checks = checks.deep_dup
      copy.rejected = rejected.deep_dup
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
      self.pending_question = nil
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

    def upsert_check!(check, correlation_id:)
      item = check.is_a?(Hash) ? check.stringify_keys : {}
      subject = item["subject"].to_s.squish.first(MAX_CHECK_CHARS)
      status = item["status"].to_s
      return if subject.blank? || CHECK_STATUSES.exclude?(status)

      result = item["result"].to_s.squish.first(MAX_CHECK_CHARS).presence
      operation = self.class.sanitize_operation(item["operation"])
      row = { "subject" => subject, "status" => status, "correlation_id" => correlation_id.to_s }
      row["result"] = result if result
      # Derived from the turn by WorkContextReducer. A historical row without
      # it is the check family. It is not a second fact the technician stated.
      row["operation"] = operation if operation
      incoming = ReportedOperation.key(subject, operation)
      index = checks.index { |stored| ReportedOperation.key(stored["subject"], stored["operation"]) == incoming }
      if index
        checks[index] = row
      else
        checks << row
        checks.shift while checks.size > MAX_CHECKS
      end
    end

    def append_observation!(text, correlation_id:, answers: nil)
      literal = text.to_s.squish.first(MAX_OBSERVATION_CHARS)
      return if literal.blank?

      stored_answers = self.class.sanitize_answers(answers)
      label = ObservationText.normalize(literal)
      existing = observations.find { |item| ObservationText.normalize(item["text"]) == label }
      if existing
        existing["answers"] = stored_answers if stored_answers
        return
      end
      return if ObservationText.redundant?(literal, observations.map { |item| ObservationText.normalize(item["text"]) })

      row = { "text" => literal, "correlation_id" => correlation_id.to_s }
      row["answers"] = stored_answers if stored_answers
      observations << row
      while observations.size > MAX_STORED_OBSERVATIONS
        index = observation_eviction_index || 0
        observations.delete_at(index)
      end
    end

    def observation_eviction_index
      goal_text = goal.is_a?(Hash) ? goal["text"].to_s : ""
      observations.each_index.find { |index|
        !ObservationText.covered_by?(goal_text, observations[index]["text"])
      }
    end

    def clear_observations!
      self.observations = []
    end

    def append_rejected!(slot, value)
      key = slot.to_s
      literal = value.to_s.squish.first(MAX_VALUE_CHARS)
      return if literal.blank? || REJECTED_SLOTS.exclude?(key)

      label = FollowupQueryRewriter.normalize_label(literal)
      rejected.reject! { |item| item["slot"] == key && FollowupQueryRewriter.normalize_label(item["value"]) == label }
      rejected << { "slot" => key, "value" => literal }
      rejected.shift while rejected.size > MAX_REJECTED
    end

    def delete_rejected!(slot, value)
      label = FollowupQueryRewriter.normalize_label(value)
      rejected.reject! { |item|
        item["slot"] == slot.to_s && FollowupQueryRewriter.normalize_label(item["value"]) == label
      }
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

      payload = serial_hash
      payload.compact!
      shrink_to_budget!(payload)
      payload
    end

    def serial_hash
      {
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
        "pending_question" => pending_question,
        "active_photo" => active_photo,
        "conflicts" => conflicts,
        "observations" => observations.presence,
        "checks" => checks.presence,
        "rejected" => rejected.presence
      }
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

    def self.sanitize_observations(raw)
      return [] unless raw.is_a?(Array)

      raw.filter_map { |item|
        next unless item.is_a?(Hash)

        text = item["text"].to_s.squish.first(MAX_OBSERVATION_CHARS)
        next if text.blank?

        row = { "text" => text, "correlation_id" => item["correlation_id"].to_s }
        answers = sanitize_answers(item["answers"])
        row["answers"] = answers if answers
        row
      }.last(MAX_STORED_OBSERVATIONS)
    end
    private_class_method :sanitize_observations

    def self.sanitize_answers(raw)
      return nil unless raw.is_a?(Hash)

      question = raw["q"].to_s.squish.first(240)
      return nil if question.blank?

      targets = Array(raw["t"]).filter_map { |item| answer_target(item) }.first(2)
      return nil if targets.empty?

      answers = { "q" => question, "t" => targets }
      about = raw["about"].to_s.squish.first(MAX_OBSERVATION_CHARS)
      answers["about"] = about if about.present?
      if raw["aspect"].to_s == "scope" && about.present?
        answers["aspect"] = "scope"
      else
        code = raw["r"].to_s
        answers["r"] = code if %w[yes no unknown].include?(code)
      end
      answers
    end

    def self.answer_target(raw)
      data = raw.is_a?(Hash) ? raw.stringify_keys : { "item" => raw }
      text = data["item"].to_s.squish.first(160)
      return nil if text.blank?

      {
        "item" => text,
        "document_key" => data["document_key"].to_s.first(240),
        "filename" => data["filename"].to_s.first(180),
        "page" => data["page"].to_s.first(12)
      }
    end

    def self.sanitize_rejected(raw)
      return [] unless raw.is_a?(Array)

      raw.filter_map { |item|
        next unless item.is_a?(Hash)

        item = item.stringify_keys
        slot = item["slot"].to_s
        value = item["value"].to_s.squish.first(MAX_VALUE_CHARS)
        next if value.blank? || REJECTED_SLOTS.exclude?(slot)

        { "slot" => slot, "value" => value }
      }.last(MAX_REJECTED)
    end
    private_class_method :sanitize_rejected

    def self.budget_refused?(payload, limit: MAX_BYTES)
      JSON.generate(payload).bytesize > limit
    end

    def self.sanitize_operation(raw)
      families = Array(raw).map(&:to_s) & ReportedOperation::ACTS.keys
      families.presence
    end

    def self.sanitize_checks(raw)
      return [] unless raw.is_a?(Array)

      raw.filter_map { |item|
        next unless item.is_a?(Hash)

        item = item.stringify_keys
        subject = item["subject"].to_s.squish.first(MAX_CHECK_CHARS)
        status = item["status"].to_s
        next if subject.blank? || CHECK_STATUSES.exclude?(status)

        row = { "subject" => subject, "status" => status, "correlation_id" => item["correlation_id"].to_s }
        result = item["result"].to_s.squish.first(MAX_CHECK_CHARS).presence
        row["result"] = result if result
        operation = sanitize_operation(item["operation"])
        row["operation"] = operation if operation
        row
      }.last(MAX_CHECKS)
    end
    private_class_method :sanitize_checks

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

      stored_checks = payload["checks"]
      if stored_checks.is_a?(Array)
        stored_checks.shift while stored_checks.any? && json_bytes(payload) > MAX_BYTES
        payload.delete("checks") if stored_checks.empty?
        return if json_bytes(payload) <= MAX_BYTES
      end

      observations = payload["observations"]
      if observations.is_a?(Array)
        observations.shift while observations.any? && json_bytes(payload) > MAX_BYTES
        payload.delete("observations") if observations.empty?
        return if json_bytes(payload) <= MAX_BYTES
      end

      identifiers = payload["identifiers"]
      return unless identifiers.is_a?(Array)

      identifiers.shift while identifiers.any? && json_bytes(payload) > MAX_BYTES
    end

    def json_bytes(payload)
      JSON.generate(payload).bytesize
    end
  end
end
