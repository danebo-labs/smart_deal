# frozen_string_literal: true

# Single write path for pilot_events. One INSERT in the same cycle as the
# structured log — no job, no broadcast, no model callbacks. Failures never
# propagate to the caller. Kill-switch: PILOT_EVENTS_PERSIST=false.
class PilotEventRecorder
  def self.record(event, payload)
    return unless persist_enabled?

    data = payload.to_h.deep_symbolize_keys
    attrs = {
      event: event.to_s,
      correlation_id: data[:correlation_id].presence,
      account_id: integer_or_nil(data[:account_id]),
      user_id: integer_or_nil(data[:user_id]),
      conversation_session_id: integer_or_nil(data[:conversation_session_id]),
      occurred_at: parse_time(data[:ts]) || Time.current,
      payload: data
    }
    # The [PILOT_USAGE] / [RAG_QUALITY] line is the telemetry. SQL debug from
    # the INSERT must not leak into the same stream — export greps and tests
    # parse those markers, and the payload JSON appears inside the SQL too.
    if (logger = ActiveRecord::Base.logger)
      logger.silence { PilotEvent.insert!(attrs, record_timestamps: true) }
    else
      PilotEvent.insert!(attrs, record_timestamps: true)
    end
  rescue StandardError => e
    Rails.logger.warn("PilotEventRecorder failed event=#{event} reason=#{e.class}")
  end

  def self.persist_enabled?
    ENV["PILOT_EVENTS_PERSIST"] != "false"
  end

  def self.integer_or_nil(value)
    Integer(value, exception: false)
  end

  def self.parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError, TypeError
    nil
  end
end
