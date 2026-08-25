# frozen_string_literal: true

class PilotTelemetryReader
  MARKERS = {
    "[PILOT_USAGE]" => :pilot,
    "[RAG_QUALITY]" => :quality,
    "[PILOT_AUDIT]" => :audit
  }.freeze
  EMPTY_STATUSES = %w[logs_not_provided logs_missing logs_unreadable].freeze

  def initialize(source:, range:, user_ids: nil, roles_declared: nil)
    @source = source
    @range = range
    @user_ids = Array(user_ids).filter_map { |value| Integer(value, exception: false) }.uniq
    @roles_declared = Array(roles_declared).filter_map { |role| role.to_s.presence }.uniq
  end

  def read
    log_data = read_from_log
    db_data = read_from_db
    merge_sources(log_data, db_data)
  end

  private

  attr_reader :source, :range, :user_ids, :roles_declared

  def read_from_log
    return result(status: "logs_not_provided") if source.blank?
    return result(status: "logs_missing") if path_source? && !File.file?(source)

    pilot = []
    quality = []
    audit = []
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

      { pilot: pilot, quality: quality, audit: audit }.fetch(bucket) << payload
    end

    first_ts = timestamps.min
    last_ts = timestamps.max
    missing_roles = roles_declared - roles_observed.uniq
    status = missing_roles.any? || !window_covered?(first_ts, last_ts) ? "partial" : "loaded"

    result(
      status: status,
      pilot: pilot,
      quality: quality,
      audit: audit,
      invalid_lines: invalid_lines,
      first_ts: first_ts&.iso8601,
      last_ts: last_ts&.iso8601,
      missing_roles: missing_roles
    )
  rescue StandardError => e
    Rails.logger.warn("PilotTelemetryReader log read failed: #{e.class}")
    result(status: "logs_unreadable")
  end

  def read_from_db
    rows = PilotEvent.hot_path_rows(range: range, user_ids: user_ids)
    return result(status: "db_empty") if rows.empty?

    pilot = []
    quality = []
    timestamps = []

    rows.each do |event, correlation_id, account_id, user_id, conversation_session_id, occurred_at, payload|
      data = reconstruct_payload(
        event: event,
        correlation_id: correlation_id,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        occurred_at: occurred_at,
        payload: payload
      )
      timestamps << occurred_at
      if event == PilotEvent::RAG_QUALITY_EVENT
        quality << data
      else
        pilot << data
      end
    end

    result(
      status: "loaded",
      source: "db",
      pilot: pilot,
      quality: quality,
      first_ts: timestamps.min&.iso8601,
      last_ts: timestamps.max&.iso8601
    )
  rescue StandardError => e
    Rails.logger.warn("PilotTelemetryReader db read failed: #{e.class}")
    result(status: "db_unreadable")
  end

  def merge_sources(log_data, db_data)
    log_usable = EMPTY_STATUSES.exclude?(log_data[:status])
    db_usable = db_data[:status] == "loaded"

    return log_data.merge(source: log_usable ? "log" : nil) unless db_usable
    return db_data unless log_usable

    merged_pilot = merge_bucket(log_data[:pilot], db_data[:pilot]) { |item| usage_key(item) }
    merged_quality = merge_bucket(log_data[:quality], db_data[:quality]) { |item| quality_key(item) }
    timestamps = [ log_data[:first_ts], log_data[:last_ts], db_data[:first_ts], db_data[:last_ts] ]
      .filter_map { |value| parse_time(value) }

    log_data.merge(
      source: "db+log",
      pilot: merged_pilot,
      quality: merged_quality,
      first_ts: timestamps.min&.iso8601 || log_data[:first_ts],
      last_ts: timestamps.max&.iso8601 || log_data[:last_ts]
    )
  end

  def merge_bucket(preferred, extra)
    seen = preferred.to_h { |item| [ yield(item), true ] }
    preferred + extra.reject { |item| seen[yield(item)] }
  end

  def usage_key(item)
    [ item[:event], item[:correlation_id], item[:ts] ]
  end

  def quality_key(item)
    [ item[:correlation_id], item[:ts] ]
  end

  def reconstruct_payload(event:, correlation_id:, account_id:, user_id:,
                          conversation_session_id:, occurred_at:, payload:)
    data = payload.to_h.deep_symbolize_keys
    data[:event] = event unless event == PilotEvent::RAG_QUALITY_EVENT
    data[:ts] ||= occurred_at&.iso8601
    data[:correlation_id] ||= correlation_id
    data[:account_id] ||= account_id
    data[:user_id] ||= user_id
    data[:conversation_session_id] ||= conversation_session_id
    data
  end

  def result(status:, source: nil, pilot: [], quality: [], audit: [], invalid_lines: 0,
             first_ts: nil, last_ts: nil, missing_roles: [])
    {
      status: status,
      source: source,
      pilot: pilot,
      quality: quality,
      audit: audit,
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
