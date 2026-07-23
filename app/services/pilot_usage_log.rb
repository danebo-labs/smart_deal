# frozen_string_literal: true

# Structured, non-blocking telemetry for pilot interactions that do not create
# a BedrockQuery row (notably photo cache hits and avoided visual calls).
class PilotUsageLog
  ALLOWED_FIELDS = %i[
    account_id user_id conversation_session_id correlation_id route model
    latency_ms original_latency_ms input_tokens output_tokens cost estimated_cost_avoided
    cache_status result error_class image_digest_prefix canonical_name
    manufacturer model_visible condition visible_codes
  ].freeze

  class << self
    def log(event, **fields)
      payload = {
        event: event.to_s,
        ts: Time.current.iso8601
      }
      fields.slice(*ALLOWED_FIELDS).each do |key, value|
        payload[key] = safe_value(value) unless value.nil?
      end
      Rails.logger.info("[PILOT_USAGE] #{JSON.generate(payload)}")
      true
    rescue StandardError => e
      Rails.logger.warn("PilotUsageLog failed event=#{event} reason=#{e.class}")
      false
    end

    private

    def safe_value(value)
      case value
      when String then value.first(500)
      when Array then value.first(20).map { |item| item.to_s.first(120) }
      when Numeric, TrueClass, FalseClass then value
      else value.to_s.first(200)
      end
    end
  end
end
