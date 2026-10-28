# frozen_string_literal: true

require "digest"
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
    ARCHIVE_STATES = %w[present absent unpack_failed].freeze
    NOTE = "A finished export is not a complete capture. uncaptured means the file does not contain that stage. unresolved_bodies lists evidence files that are not in this directory or whose bytes do not match the recorded sha256. This index does not reconstruct them."

    def self.build(directory, archive: nil)
      new(directory, archive: archive).build
    end

    def initialize(directory, archive: nil)
      @directory = Pathname(directory.to_s)
      unless archive.nil? || ARCHIVE_STATES.include?(archive)
        raise ArgumentError, "unknown validation archive state"
      end

      @archive = archive
    end

    def build
      return closed_document("unreadable", "unpack_failed") if @archive == "unpack_failed"
      return closed_document("absent", "absent") if @archive == "absent"

      files = capture_files
      turns = files.flat_map { |path| turns_for(path) }
      document = {
        "status" => status_for(files, turns),
        "capture_files" => files.size,
        "turns" => turns,
        "note" => NOTE
      }
      document["archive"] = @archive if @archive
      document
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
      unresolved = unresolved_bodies(path, body_references(events))
      groups.map { |correlation_id| turn_row(relative, correlation_id, events, unresolved, attach_unscoped: groups.one?) }
    rescue StandardError => error
      [ {
        "path" => path.to_s,
        "status" => "unreadable",
        "error_class" => error.class.name
      } ]
    end

    def turn_row(path, correlation_id, events, unresolved, attach_unscoped:)
      mine = events.select { |event|
        label = event_correlation(event)
        label == correlation_id || (attach_unscoped && label.nil?)
      }
      # index_with belongs to ActiveSupport. bin/pilot_metrics loads this file
      # with plain Ruby, so the hash is built here.
      components = COMPONENTS.to_h { |name| [ name, component_status(name, mine) ] } # rubocop:disable Rails/IndexWith
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
        "markers" => markers(mine),
        "unresolved_bodies" => unresolved,
        "status" => (components.value?("uncaptured") || unresolved.any?) ? "partial" : "complete"
      }
    end

    def closed_document(status, archive)
      {
        "status" => status,
        "archive" => archive,
        "capture_files" => 0,
        "turns" => [],
        "note" => NOTE
      }
    end

    def body_references(events)
      found = []
      walk_bodies(events, found)
      found.uniq { |reference| reference["path"] }
    end

    def walk_bodies(value, found)
      case value
      when Hash
        if value["evidence"] == "external" && value["path"].is_a?(String) && value["absent"] != true
          found << { "path" => value["path"], "sha256" => value["sha256"] }
        end
        value.each_value { |child| walk_bodies(child, found) }
      when Array
        value.each { |child| walk_bodies(child, found) }
      end
    end

    # path is relative to the directory that contains capture.json, which is
    # where ValidationCapture writes bodies/. A missing file stays missing.
    def unresolved_bodies(capture_json, references)
      root = capture_json.dirname
      references.filter_map { |reference| unresolved_body(root, reference) }
    end

    def unresolved_body(root, reference)
      relative = reference["path"]
      return { "path" => relative, "status" => "absent" } unless contained_body?(relative)

      file = root.join(relative)
      return { "path" => relative, "status" => "absent" } if file.symlink? || !file.file?

      expected = reference["sha256"]
      return nil unless expected.is_a?(String) && !expected.empty?
      return nil if Digest::SHA256.file(file).hexdigest == expected

      { "path" => relative, "status" => "hash_mismatch" }
    end

    def contained_body?(relative)
      return false if relative.empty? || relative.start_with?("/", "\\") || relative.include?("\0")

      parts = Pathname(relative).each_filename.to_a
      !parts.empty? && parts.none? { |part| part == "." || part == ".." }
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

    def markers(events)
      found = []
      events.each do |event|
        found << "capture_probe" if event["kind"] == "capture_probe" || event["question"] == "capture_probe"
      end
      found.uniq
    end

    def event_correlation(event)
      [ event["correlation_root"], event["correlation_id"] ].each do |value|
        return value.to_s if filled?(value)
      end
      nil
    end

    def filled?(value)
      return false if value.nil? || value == false
      return !value.empty? if value.respond_to?(:empty?)

      true
    end

    def published_text?(events)
      events.any? { |event|
        (event["kind"] == "published_answer" && filled?(event["answer"])) ||
          (event["kind"] == "companion_plan" && filled?(event["rendered"])) ||
          (event["kind"] == "assistant_history" && filled?(event["presented"]))
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
      return direct if filled?(direct)

      events.each do |event|
        next unless event["kind"] == "episode_delta"

        [ event["episode_after"], event["episode_before"] ].each do |snapshot|
          next unless snapshot.is_a?(Hash) && filled?(snapshot["episode_id"])

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
