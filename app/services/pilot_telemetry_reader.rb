# frozen_string_literal: true

class PilotTelemetryReader
  MARKERS = {
    "[PILOT_USAGE]" => :pilot,
    "[RAG_QUALITY]" => :quality
  }.freeze

  def initialize(source:, range:, user_ids: nil, roles_declared: nil)
    @source = source
    @range = range
    @user_ids = Array(user_ids).filter_map { |value| Integer(value, exception: false) }.uniq
    @roles_declared = Array(roles_declared).filter_map { |role| role.to_s.presence }.uniq
  end

  def read
    return result(status: "logs_not_provided") if source.blank?
    return result(status: "logs_missing") if path_source? && !File.file?(source)

    pilot = []
    quality = []
    invalid_lines = 0
    timestamps = []
    roles_observed = []

    each_line do |line|
      marker, bucket = MARKERS.find { |candidate, _name| line.include?(candidate) }
      next unless marker

      payload = extract_json(line, marker)
      unless payload
        invalid_lines += 1
        next
      end

      timestamp = payload_time(payload, line)
      timestamps << timestamp if timestamp
      roles_observed << payload[:role].to_s if payload[:role].present?
      next unless timestamp && range.cover?(timestamp) && cohort_payload?(payload)

      (bucket == :pilot ? pilot : quality) << payload
    end

    first_ts = timestamps.min
    last_ts = timestamps.max
    missing_roles = roles_declared - roles_observed.uniq
    status = missing_roles.any? || !window_covered?(first_ts, last_ts) ? "partial" : "loaded"

    result(
      status: status,
      pilot: pilot,
      quality: quality,
      invalid_lines: invalid_lines,
      first_ts: first_ts&.iso8601,
      last_ts: last_ts&.iso8601,
      missing_roles: missing_roles
    )
  rescue StandardError => e
    Rails.logger.warn("PilotTelemetryReader log read failed: #{e.class}")
    result(status: "logs_unreadable")
  end

  private

  attr_reader :source, :range, :user_ids, :roles_declared

  def result(status:, pilot: [], quality: [], invalid_lines: 0, first_ts: nil, last_ts: nil, missing_roles: [])
    {
      status: status,
      pilot: pilot,
      quality: quality,
      invalid_lines: invalid_lines,
      first_ts: first_ts,
      last_ts: last_ts,
      roles_declared: roles_declared,
      missing_roles: missing_roles
    }
  end

  def path_source?
    source.is_a?(String)
  end

  def each_line(&block)
    if path_source?
      File.foreach(source, &block)
    else
      source.each_line(&block)
    end
  end

  def extract_json(line, marker)
    marker_index = line.index(marker)
    JSON.parse(line[(marker_index + marker.length)..].strip).deep_symbolize_keys
  rescue JSON::ParserError
    nil
  end

  def payload_time(payload, line)
    parse_time(payload[:ts]) || parse_time(line[/\d{4}-\d{2}-\d{2}T[^\s]+/])
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError, TypeError
    nil
  end

  def cohort_payload?(payload)
    user_ids.empty? || user_ids.include?(Integer(payload[:user_id], exception: false))
  end

  def window_covered?(first_ts, last_ts)
    first_ts && last_ts && first_ts <= range.begin && last_ts >= range.end.change(usec: 0)
  end
end
