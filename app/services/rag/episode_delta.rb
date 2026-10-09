# frozen_string_literal: true

module Rag
  # Diff of the episode fields a turn actually changed, plus the episode
  # hashes read before and after. No-op unless a validation capture is open.
  module EpisodeDelta
    module_function

    def record(before, after, correlation_id: nil)
      return unless ValidationCapture.active?

      before = before || ActiveEpisode.new
      after = after || ActiveEpisode.new
      delta = {}
      goal_before = goal_text(before)
      goal_after = goal_text(after)
      delta["goal"] = { "before" => goal_before, "after" => goal_after } if goal_before != goal_after
      assign_list(delta, "identifiers", identifier_values(before), identifier_values(after))
      assign_list(delta, "facts", fact_rows(before), fact_rows(after))
      assign_list(delta, "observations", observation_texts(before), observation_texts(after))
      assign_list(delta, "rejected", rejected_rows(before), rejected_rows(after))
      pending_before = pending_text(before)
      pending_after = pending_text(after)
      if pending_before != pending_after
        delta["pending_question"] = { "before" => pending_before, "after" => pending_after }
      end
      if before.episode_id.to_s != after.episode_id.to_s && (before.episode_id.present? || after.episode_id.present?)
        delta["episode"] = { "before" => before.episode_id, "after" => after.episode_id }
      end

      payload = {
        "stage" => "episode",
        "changed" => delta.any?,
        "episode_before" => episode_snapshot(before),
        "episode_after" => episode_snapshot(after)
      }
      payload["episode_id"] = after.episode_id if after.episode_id.present?
      payload.merge!(delta)
      payload["correlation_id"] = correlation_id if correlation_id.present?
      ValidationCapture.record("episode_delta", payload)
    end

    def assign_list(delta, key, before_rows, after_rows)
      added = after_rows - before_rows
      removed = before_rows - after_rows
      return if added.empty? && removed.empty?

      delta[key] = { "added" => added, "removed" => removed }
    end

    def episode_snapshot(episode)
      return {} unless episode.respond_to?(:to_h)

      snapshot = episode.to_h
      snapshot.is_a?(Hash) ? snapshot : {}
    end

    def goal_text(episode)
      goal = episode.respond_to?(:goal) ? episode.goal : nil
      return goal["text"].to_s if goal.is_a?(Hash)

      goal.to_s.presence
    end

    def identifier_values(episode)
      Array(episode.respond_to?(:identifiers) ? episode.identifiers : nil).filter_map { |row|
        value = row.is_a?(Hash) ? row["value"] : row
        value.to_s.presence
      }
    end

    def fact_rows(episode)
      facts = episode.respond_to?(:facts) ? episode.facts : {}
      Array(facts).filter_map { |slot, fact|
        next unless fact.is_a?(Hash)

        "#{slot}:#{fact["status"]}:#{fact["value"]}"
      }.sort
    end

    def observation_texts(episode)
      Array(episode.respond_to?(:observations) ? episode.observations : nil).filter_map { |row|
        text = row.is_a?(Hash) ? row["text"] : row
        text.to_s.presence
      }
    end

    def rejected_rows(episode)
      Array(episode.respond_to?(:rejected) ? episode.rejected : nil).filter_map { |row|
        next unless row.is_a?(Hash)

        "#{row["slot"]}:#{row["value"]}"
      }
    end

    def pending_text(episode)
      question = episode.respond_to?(:pending_question) ? episode.pending_question : nil
      return nil if question.blank?
      return question.to_json if question.is_a?(Hash)

      question.to_s
    end
  end
end
