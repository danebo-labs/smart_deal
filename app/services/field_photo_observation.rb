# frozen_string_literal: true

# Allowlisted visual reading stored on the same field_photos row.
# Invalid payloads are rejected whole. Strings are not truncated.
class FieldPhotoObservation
  SCHEMA_VERSION = 1
  MAX_BYTES = 2048
  MAX_CHARS = 80
  MAX_VISIBLE_TEXT = 8
  FINGERPRINT_RE = /\A[0-9a-f]{64}\z/
  CONDITIONS = %w[GOOD DEGRADED DAMAGED UNKNOWN].freeze
  RELEVANCE = %w[relevant unrelated uncertain].freeze
  # Locked to FieldPhotoPrompt's subsystem enum. Do not widen it here.
  SUBSYSTEMS = %w[
    SAFETY_CHAIN
    BRAKE_SYSTEM
    DOOR_OPERATOR
    MOTOR_DRIVE
    GOVERNOR_SYSTEM
    CONTROLLER_LOGIC
    POWER_SUPPLY
    SIGNALING_SYSTEM
    EMERGENCY_SYSTEM
    PIT_EQUIPMENT
    CAR_TOP_EQUIPMENT
    UNKNOWN
  ].freeze
  KEYS = %w[
    schema_version
    prompt_fingerprint
    model_id
    canonical_component
    manufacturer
    model
    subsystem
    condition
    visible_text
    target_visible
    relevance_to_goal
  ].freeze

  class << self
    def sanitize(raw)
      payload = build_payload(raw)
      return nil if payload.nil?
      return nil if JSON.generate(payload).bytesize > MAX_BYTES

      payload
    end

    def persist!(photo, raw)
      return nil if photo.nil?

      sanitized = sanitize(raw)
      return nil if sanitized.nil?

      photo.update!(visual_observation: sanitized)
      sanitized
    end

    def from_analysis(parsed:, model_id:)
      data = parsed.to_h.stringify_keys
      {
        "schema_version" => SCHEMA_VERSION,
        "prompt_fingerprint" => FieldPhotoPrompt.prompt_fingerprint_sha256,
        "model_id" => model_id,
        "canonical_component" => data["canonical_component"],
        "manufacturer" => data["manufacturer"],
        "model" => data["model"],
        "subsystem" => data["subsystem"],
        "condition" => data["condition"],
        "visible_text" => data["visible_text"],
        "target_visible" => data.key?("target_visible") ? data["target_visible"] : nil,
        "relevance_to_goal" => data.key?("relevance_to_goal") ? data["relevance_to_goal"] : nil
      }
    end

    # Shape the existing photo-answer path already reads. No model prose.
    def reading_value(observation)
      observation = sanitize(observation)
      return nil if observation.nil?

      codes = observation["visible_text"]
      line = [
        "[FOTO] Componente: #{observation['canonical_component']}",
        "Fabricante: #{observation['manufacturer']}",
        "Modelo: #{observation['model']}",
        "Códigos: #{codes.presence&.join(', ') || 'UNKNOWN'}",
        "Condición: #{observation['condition']}"
      ].join(" | ")
      line = line.truncate(ConversationSession::MAX_MSG_LENGTH, omission: "...")
      {
        analysis: line,
        compact_context: line,
        canonical_name: observation["canonical_component"],
        aliases: [],
        manufacturer: observation["manufacturer"],
        model_visible: observation["model"],
        condition: observation["condition"],
        visible_codes: codes,
        target_visible: observation["target_visible"],
        relevance_to_goal: observation["relevance_to_goal"],
        missing_view_or_detail: nil
      }
    end

    private

    def build_payload(raw)
      return nil unless raw.is_a?(Hash)

      data = raw.stringify_keys
      schema_version = data["schema_version"]
      return nil unless schema_version.is_a?(Integer) && schema_version == SCHEMA_VERSION

      fingerprint = data["prompt_fingerprint"]
      return nil unless fingerprint.is_a?(String) && FINGERPRINT_RE.match?(fingerprint)

      model_id = bounded_string(data["model_id"])
      component = bounded_string(data["canonical_component"])
      manufacturer = bounded_string(data["manufacturer"])
      model = bounded_string(data["model"])
      visible_text = visible_text_list(data["visible_text"])
      target_visible = nullable_boolean(data, "target_visible")
      relevance = nullable_relevance(data)
      return nil if model_id.nil? || component.nil? || manufacturer.nil? || model.nil?
      return nil unless SUBSYSTEMS.include?(data["subsystem"])
      return nil unless CONDITIONS.include?(data["condition"])
      return nil if visible_text.nil? || target_visible == :invalid || relevance == :invalid

      {
        "schema_version" => schema_version,
        "prompt_fingerprint" => fingerprint,
        "model_id" => model_id,
        "canonical_component" => component,
        "manufacturer" => manufacturer,
        "model" => model,
        "subsystem" => data["subsystem"],
        "condition" => data["condition"],
        "visible_text" => visible_text,
        "target_visible" => target_visible,
        "relevance_to_goal" => relevance
      }
    end

    def bounded_string(value)
      return nil unless value.is_a?(String)
      return nil if value.empty? || value.length > MAX_CHARS

      value
    end

    def visible_text_list(value)
      return nil unless value.is_a?(Array)
      return nil if value.size > MAX_VISIBLE_TEXT

      items = []
      value.each do |item|
        text = bounded_string(item)
        return nil if text.nil?

        items << text
      end
      items
    end

    def nullable_boolean(data, key)
      return nil unless data.key?(key)

      value = data[key]
      return value if value == true || value == false || value.nil?

      :invalid
    end

    def nullable_relevance(data)
      return nil unless data.key?("relevance_to_goal")

      value = data["relevance_to_goal"]
      return nil if value.nil?
      return value if value.is_a?(String) && RELEVANCE.include?(value)

      :invalid
    end
  end
end
