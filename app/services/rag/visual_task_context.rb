# frozen_string_literal: true

require "json"

module Rag
  # Bounded input for one live field-photo Vision call.
  # Context is not evidence: this object never becomes manufacturer, model,
  # code, condition, or visible text. Those still come only from the image.
  #
  # previous_visual_evidence is reserved for F5 and is not emitted.
  class VisualTaskContext
    SCHEMA_VERSION = 1
    MAX_BYTES = 1600
    MAX_GOAL_CHARS = 240
    MAX_EQUIPMENT_CHARS = 60
    MAX_OBSERVATIONS = 2
    MAX_OBSERVATION_CHARS = 120
    MAX_TASK_CHARS = 240
    EQUIPMENT_KEYS = %w[manufacturer model controller fault_code].freeze
    # Least useful to the relevance judgment goes first.
    EQUIPMENT_DROP_ORDER = %w[fault_code controller model manufacturer].freeze
    PENDING_TYPES = ActiveEpisode::PENDING_SUBJECTS
    STEMS = %w[
      resorte fijacion cable terminal amarre polea puerta cabina botonera
      placa tarjeta contactor freno motor limitador spring rope sheave door
      board brake
    ].freeze
    ALLOWED_KEYS = %w[
      schema_version mode goal equipment_context observations pending visual_task
    ].freeze

    def self.build(question:, episode_state:, history:, now:)
      episode = ActiveEpisode.parse(episode_state, now: now)
      episode = nil if episode.blank?
      visual_task = resolve_visual_task(question: question, episode: episode, history: history, now: now)
      goal = goal_text(episode)
      equipment = equipment_context(episode)
      observations = observation_texts(episode)
      pending = pending_type(episode)
      meaningful = goal.present? || equipment.present? || observations.any? || pending.present?

      payload = {
        "schema_version" => SCHEMA_VERSION,
        "mode" => (meaningful ? "ongoing_episode" : "standalone")
      }
      payload["goal"] = goal if goal
      payload["equipment_context"] = equipment if equipment.present?
      payload["observations"] = observations if observations.any?
      payload["pending"] = { "type" => pending } if pending
      payload["visual_task"] = visual_task if visual_task
      new(fit!(payload))
    end

    def self.coerce(value)
      case value
      when nil then nil
      when self then value
      when Hash
        payload = value.deep_stringify_keys
        return nil unless payload["schema_version"] == SCHEMA_VERSION
        return nil unless %w[standalone ongoing_episode].include?(payload["mode"])

        new(payload)
      end
    end

    def initialize(payload)
      @payload = payload
    end

    def to_h
      @payload
    end

    def bytesize
      JSON.generate(@payload).bytesize
    end

    def mode
      @payload["mode"]
    end

    def goal
      @payload["goal"]
    end

    def visual_task
      @payload["visual_task"]
    end

    def visual_task?
      text = visual_task.is_a?(Hash) ? visual_task["text"] : nil
      text.present?
    end

    def ongoing_episode?
      mode == "ongoing_episode"
    end

    def relevance_anchor?
      visual_task? || ongoing_episode?
    end

    def self.visual_target?(text)
      tokens = I18n.transliterate(text.to_s).downcase.scan(/[a-z0-9]+/)
      tokens.any? { |token| STEMS.any? { |stem| token.start_with?(stem) } }
    end

    def self.resolve_visual_task(question:, episode:, history:, now:)
      asked = bound(question, MAX_TASK_CHARS)
      return { "text" => asked, "source" => "question" } if asked

      return nil if episode.nil?

      window_start = now - ConversationSession::EPISODE_WINDOW
      opened = parse_time(episode.opened_at)
      window_start = [ window_start, opened ].max if opened

      Array(history).reverse_each do |message|
        next unless message.is_a?(Hash)

        row = message.stringify_keys
        next unless row["role"] == "user"

        ts = parse_time(row["ts"])
        next if ts.nil? || ts < window_start || ts > now
        next unless visual_target?(row["content"])

        text = bound(row["content"], MAX_TASK_CHARS)
        return { "text" => text, "source" => "recent_user_target" } if text
      end

      goal = episode.goal.is_a?(Hash) ? episode.goal["text"] : nil
      return nil unless visual_target?(goal)

      text = bound(goal, MAX_TASK_CHARS)
      return { "text" => text, "source" => "goal" } if text

      nil
    end
    private_class_method :resolve_visual_task

    def self.goal_text(episode)
      return nil if episode.nil?

      bound(episode.goal.is_a?(Hash) ? episode.goal["text"] : nil, MAX_GOAL_CHARS)
    end
    private_class_method :goal_text

    def self.equipment_context(episode)
      return {} if episode.nil?

      EQUIPMENT_KEYS.each_with_object({}) do |key, kept|
        fact = episode.fact(key)
        next unless fact.is_a?(Hash) && fact["status"] == "known"

        value = bound(fact["value"], MAX_EQUIPMENT_CHARS)
        kept[key] = value if value
      end
    end
    private_class_method :equipment_context

    def self.observation_texts(episode)
      return [] if episode.nil?

      Array(episode.observations).last(MAX_OBSERVATIONS).filter_map do |item|
        next unless item.is_a?(Hash)

        bound(item["text"], MAX_OBSERVATION_CHARS)
      end
    end
    private_class_method :observation_texts

    def self.pending_type(episode)
      return nil if episode.nil?

      question_type = episode.pending_question&.dig("type").to_s
      return question_type if PENDING_TYPES.include?(question_type)
      return nil if episode.pending_question.present?

      subject = episode.pending_fact&.dig("subject").to_s
      PENDING_TYPES.include?(subject) ? subject : nil
    end
    private_class_method :pending_type

    def self.bound(text, limit)
      text.to_s.squish.first(limit).presence
    end
    private_class_method :bound

    def self.parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end
    private_class_method :parse_time

    # Drop order: observations (oldest first), equipment keys, pending,
    # then goal, then visual_task text. schema_version and mode stay.
    # Mode is the pre-drop decision and is not recomputed.
    def self.fit!(payload)
      return payload if bytes(payload) <= MAX_BYTES

      observations = payload["observations"]
      if observations.is_a?(Array)
        observations.shift while observations.any? && bytes(payload) > MAX_BYTES
        payload.delete("observations") if observations.empty?
        return payload if bytes(payload) <= MAX_BYTES
      end

      equipment = payload["equipment_context"]
      if equipment.is_a?(Hash)
        EQUIPMENT_DROP_ORDER.each do |key|
          break if bytes(payload) <= MAX_BYTES

          equipment.delete(key)
        end
        payload.delete("equipment_context") if equipment.empty?
        return payload if bytes(payload) <= MAX_BYTES
      end

      payload.delete("pending") if bytes(payload) > MAX_BYTES
      return payload if bytes(payload) <= MAX_BYTES

      shrink_string!(payload, "goal")
      return payload if bytes(payload) <= MAX_BYTES

      task = payload["visual_task"]
      if task.is_a?(Hash)
        task["text"] = task["text"].to_s
        while task["text"].present? && bytes(payload) > MAX_BYTES
          task["text"] = task["text"].chop
        end
        payload.delete("visual_task") if task["text"].blank?
      end
      payload
    end
    private_class_method :fit!

    def self.shrink_string!(payload, key)
      text = payload[key].to_s
      while text.present? && bytes(payload) > MAX_BYTES
        text = text.chop
        payload[key] = text
      end
      payload.delete(key) if payload[key].blank?
    end
    private_class_method :shrink_string!

    def self.bytes(payload)
      JSON.generate(payload).bytesize
    end
    private_class_method :bytes
  end
end
