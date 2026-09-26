# frozen_string_literal: true

module Rag
  # Technician words a live field photo is read against.
  # Explicit question, then the newest visual-target user message inside the
  # episode window, then a visual-target goal. Assistant prose is never used.
  class PhotoIntent
    STEMS = %w[
      resorte fijacion cable terminal amarre polea puerta cabina botonera
      placa tarjeta contactor freno motor limitador spring rope sheave door
      board brake
    ].freeze

    def self.resolve(question:, episode_state:, history:, now:)
      asked = bounded(question)
      return { "text" => asked, "source" => "question" } if asked.present?

      episode = ActiveEpisode.parse(episode_state, now: now)
      return nil if episode.blank?

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

        text = bounded(row["content"])
        return { "text" => text, "source" => "history" } if text.present?
      end

      goal = episode.goal.is_a?(Hash) ? episode.goal["text"] : nil
      if visual_target?(goal)
        text = bounded(goal)
        return { "text" => text, "source" => "goal" } if text.present?
      end

      nil
    end

    def self.visual_target?(text)
      tokens = I18n.transliterate(text.to_s).downcase.scan(/[a-z0-9]+/)
      tokens.any? { |token| STEMS.any? { |stem| token.start_with?(stem) } }
    end

    def self.bounded(text)
      text.to_s.squish.first(ActiveEpisode::MAX_GOAL_CHARS)
    end
    private_class_method :bounded

    def self.parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end
    private_class_method :parse_time
  end
end
