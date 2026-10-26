# frozen_string_literal: true

require "json"
require "pathname"

module Rag
  # Reads ValidationCapture files already written for a run. It does not open
  # a capture, call a model, or fill a missing stage. A missing event stays
  # uncaptured. An export that finishes is not a complete capture.
  class ValidationCaptureIndex
    COMPONENTS = %w[
      episode_snapshot
      interpreter
      perception
      companion_plan
      checker_reasons
      published_text
      antecedent
    ].freeze

    def self.build(directory)
      new(directory).build
    end

    def initialize(directory)
      @directory = Pathname(directory.to_s)
    end

    def build
      files = capture_files
      turns = files.flat_map { |path| turns_for(path) }
      {
        "status" => status_for(files, turns),
        "capture_files" => files.size,
        "turns" => turns,
        "note" => "A finished export is not a complete capture. uncaptured means the file does not contain that stage. This index does not reconstruct it."
      }
    end

    private

    def capture_files
      return [] unless @directory.directory?

      Dir.glob(@directory.join("**", "capture.json").to_s).sort.map { |path| Pathname(path) }
    end

    def turns_for(path)
      document = JSON.parse(path.read)
      events = Array(document["events"]).select { |event| event.is_a?(Hash) }
      relative = path.relative_path_from(@directory).to_s
      correlations = events.filter_map { |event| event_correlation(event) }.uniq
      groups = correlations.empty? ? [ nil ] : correlations
      groups.map { |correlation_id| turn_row(relative, correlation_id, events, attach_unscoped: groups.one?) }
    rescue StandardError => error
      [ {
        "path" => path.to_s,
        "status" => "unreadable",
        "error_class" => error.class.name
      } ]
    end

    def turn_row(path, correlation_id, events, attach_unscoped:)
      mine = events.select { |event|
        label = event_correlation(event)
        label == correlation_id || (attach_unscoped && label.nil?)
      }
      components = COMPONENTS.index_with { |name| component_status(name, mine) }
      truncated = truncation(mine)
      {
        "path" => path,
        "correlation_id" => correlation_id,
        "account_id" => first_value(mine, "account_id"),
        "user_id" => first_value(mine, "user_id"),
        "session_id" => first_value(mine, "session_id"),
        "episode_id" => episode_label(mine),
        "kamal_version" => contract_value(mine, "kamal_version"),
        "capture_scope" => contract_value(mine, "capture_scope"),
        "components" => components,
        "truncated_fields" => truncated,
        "status" => components.value?("uncaptured") ? "partial" : "complete"
      }
    end

    def component_status(name, events)
      case name
      when "episode_snapshot"
        episode_snapshot?(events) ? "present" : "uncaptured"
      when "interpreter"
        events.any? { |event| %w[interpreter_raw interpreter_failure].include?(event["kind"]) } ? "present" : "uncaptured"
      when "perception"
        events.any? { |event| event["kind"] == "perception_applied" } ? "present" : "uncaptured"
      when "companion_plan"
        events.any? { |event| event["kind"] == "companion_plan" && event["tool_input"].is_a?(Hash) } ? "present" : "uncaptured"
      when "checker_reasons"
        checker_reasons?(events) ? "present" : "uncaptured"
      when "published_text"
        published_text?(events) ? "present" : "uncaptured"
      when "antecedent"
        antecedent?(events) ? "present" : "uncaptured"
      else
        "uncaptured"
      end
    end

    def episode_snapshot?(events)
      events.any? { |event|
        event["kind"] == "episode_delta" && event["episode_before"].is_a?(Hash) && event["episode_after"].is_a?(Hash)
      }
    end

    def checker_reasons?(events)
      events.any? { |event|
        next false unless event["kind"] == "companion_plan"

        reasons = event.dig("check", "rejections")
        reasons.is_a?(Array) && reasons.all? { |row| row.is_a?(Hash) && row.key?("reason") }
      }
    end

    def event_correlation(event)
      event["correlation_root"].to_s.presence || event["correlation_id"].to_s.presence
    end

    def published_text?(events)
      events.any? { |event|
        (event["kind"] == "published_answer" && event["answer"].present?) ||
          (event["kind"] == "companion_plan" && event["rendered"].present?) ||
          (event["kind"] == "assistant_history" && event["presented"].present?)
      }
    end

    def antecedent?(events)
      events.any? { |event|
        event["kind"] == "assistant_history" && event["result"] == "stored" && event.key?("prompt_reply")
      }
    end

    def truncation(events)
      found = []
      events.each { |event| walk_truncation(event, found) }
      found
    end

    def walk_truncation(value, found)
      case value
      when Hash
        if value["summary_truncated"] == true
          found << {
            "field" => value["field"],
            "path" => value["path"],
            "summary_truncated" => true,
            "body_truncated" => value["truncated"] == true,
            "bytes" => value["bytes"]
          }
        end
        value.each_value { |child| walk_truncation(child, found) }
      when Array
        value.each { |child| walk_truncation(child, found) }
      end
    end

    def episode_label(events)
      direct = first_value(events, "episode_id")
      return direct if direct.present?

      events.each do |event|
        next unless event["kind"] == "episode_delta"

        [ event["episode_after"], event["episode_before"] ].each do |snapshot|
          next unless snapshot.is_a?(Hash) && snapshot["episode_id"].present?

          return snapshot["episode_id"]
        end
      end
      nil
    end

    def first_value(events, key)
      events.each do |event|
        value = event[key]
        return value unless value.nil?
      end
      nil
    end

    def contract_value(events, key)
      events.each do |event|
        next unless event["kind"] == "process_contract"

        return event[key] if event.key?(key)
      end
      nil
    end

    def status_for(files, turns)
      return "absent" if files.empty?
      return "unreadable" if turns.any? { |turn| turn["status"] == "unreadable" }
      return "complete" if turns.any? && turns.all? { |turn| turn["status"] == "complete" }

      "partial"
    end
  end
end
