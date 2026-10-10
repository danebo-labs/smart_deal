# frozen_string_literal: true

module Rag
  # Reads the capture a turn already wrote. It does not perceive, reduce,
  # route, or compose, and it does not replace the historical judgment.
  class JourneyReview
    def self.summarize(events)
      route = find(events, "route_decision")
      delta = find(events, "episode_delta")
      query = find(events, "effective_query")
      focus = find(events, "document_focus")
      perception = find(events, "perception_applied")
      exit_event = find(events, "route_exit")
      message = find(events, "user_message")
      before = delta["episode_before"].is_a?(Hash) ? delta["episode_before"] : {}
      after = delta["episode_after"].is_a?(Hash) ? delta["episode_after"] : {}

      {
        "route" => route["route"],
        "condition" => route["condition"],
        "retrieval" => route["retrieval"],
        "fallback" => route["fallback"],
        "exit" => exit_event["exit"],
        "exit_condition" => exit_event["condition"],
        "invalid_reason" => perception["invalid_reason"],
        "move" => perception["move"],
        "original_move" => perception["original_move"],
        "adjustments" => Array(perception["adjustments"]),
        "query" => query["effective"].to_s,
        "composed" => query["composed"],
        "episode_before" => before,
        "episode_after" => after,
        "episode_before_id" => before["episode_id"],
        "episode_after_id" => after["episode_id"],
        "goal_before" => text_of(before["goal"]),
        "goal_after" => text_of(after["goal"]),
        "observations_before" => texts(before["observations"]),
        "observations_after" => texts(after["observations"]),
        "identifiers_before" => values(before["identifiers"]),
        "identifiers_after" => values(after["identifiers"]),
        "facts_before" => before["facts"].is_a?(Hash) ? before["facts"] : {},
        "facts_after" => after["facts"].is_a?(Hash) ? after["facts"] : {},
        "model_after" => fact_value(after, "model"),
        "manufacturer_after" => fact_value(after, "manufacturer"),
        "fault_code_after" => fact_value(after, "fault_code"),
        "writes" => delta.slice("goal", "observations", "identifiers", "facts", "episode"),
        "focus_before" => focus_ids(focus["before"]),
        "focus_after" => focus_ids(focus["after"]),
        "audited_turn" => message["original"].to_s
      }
    end

    # `checks` are the case expectations. Historical acceptance is copied
    # through and is not recomputed from this route.
    def self.judge(summary, checks)
      reasons = []
      query = summary["query"].to_s
      Array(checks[:query_includes]).each do |fragment|
        reasons << "query_missing" unless query.include?(fragment)
      end
      if checks[:retrieval] == true && summary["retrieval"] != true
        reasons << "not_retrieved"
      elsif checks[:retrieval] == false && summary["retrieval"] == true
        reasons << "retrieved"
      end
      reasons << "model_written" if checks[:forbid_model] && summary["model_after"].present?
      reasons << "fault_code_written" if checks[:forbid_fault_code] && summary["fault_code_after"].present?
      Array(checks[:forbidden_identifiers]).each do |value|
        reasons << "symptom_identifier" if summary["identifiers_after"].include?(value)
      end
      if checks[:focus_stable] && summary["focus_before"] != summary["focus_after"]
        reasons << "focus_changed"
      end
      if checks[:episode_stable] && summary["episode_before_id"].present? &&
          summary["episode_before_id"] != summary["episode_after_id"]
        reasons << "silent_restart"
      end
      if checks[:prior_goal] && summary["goal_after"] != checks[:prior_goal]
        reasons << "goal_replaced"
      end
      if checks[:no_unconfirmed_writes]
        reasons << "goal_written" if summary["goal_before"] != summary["goal_after"]
        reasons << "observation_written" if summary["observations_before"] != summary["observations_after"]
        reasons << "identifier_written" if summary["identifiers_before"] != summary["identifiers_after"]
        reasons << "fact_written" if fact_values(summary["facts_before"]) != fact_values(summary["facts_after"])
      end
      reasons << "turn_not_audited" if checks[:audited_turn] && summary["audited_turn"] != checks[:audited_turn]
      if checks[:manufacturer] && summary["manufacturer_after"] != checks[:manufacturer]
        reasons << "manufacturer"
      end
      if checks[:manufacturer_blank] && summary["manufacturer_after"].present?
        reasons << "manufacturer_written"
      end

      {
        "acceptance" => reasons.empty? ? "pass" : "fail",
        "reasons" => reasons,
        "historical" => checks[:historical]
      }
    end

    def self.find(events, kind)
      events.find { |event| event["kind"] == kind } || {}
    end

    def self.text_of(goal)
      return goal["text"].to_s.presence if goal.is_a?(Hash)

      goal.to_s.presence
    end

    def self.texts(rows)
      Array(rows).filter_map { |row| row.is_a?(Hash) ? row["text"].to_s.presence : row.to_s.presence }
    end

    def self.values(rows)
      Array(rows).filter_map { |row| row.is_a?(Hash) ? row["value"].to_s.presence : row.to_s.presence }
    end

    def self.fact_value(episode, slot)
      fact = episode.dig("facts", slot)
      fact.is_a?(Hash) ? fact["value"].to_s.presence : nil
    end

    def self.fact_values(facts)
      facts.to_h.each_with_object({}) { |(slot, fact), copy|
        next unless fact.is_a?(Hash)

        copy[slot.to_s] = fact["value"].to_s
      }
    end

    def self.focus_ids(entries)
      Array(entries).filter_map { |entry| entry["kb_document_id"] if entry.is_a?(Hash) }
    end
  end
end
