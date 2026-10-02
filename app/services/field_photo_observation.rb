# frozen_string_literal: true

# Allowlisted visual reading stored on the same field_photos row.
# from_analysis projects a bounded candidate. sanitize rejects the envelope
# whole. Strings are not truncated.
class FieldPhotoObservation
  SCHEMA_VERSION = 1
  MAX_BYTES = 2048
  MAX_CHARS = 80
  MAX_VISIBLE_TEXT = 8
  FINGERPRINT_RE = /\A[0-9a-f]{64}\z/
  CONDITIONS = %w[GOOD DEGRADED DAMAGED UNKNOWN].freeze
  RELEVANCE = %w[relevant unrelated uncertain].freeze
  Acceptance = Struct.new(:status, :observation, :reason, keyword_init: true)
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

    # Bounded projection. target_visible and relevance_to_goal are the values
    # FieldPhotoAnalysisService already normalized. They are not read from parsed.
    def from_analysis(parsed:, model_id:, target_visible: nil, relevance_to_goal: nil)
      data = parsed.to_h.stringify_keys
      payload = {
        "schema_version" => SCHEMA_VERSION,
        "prompt_fingerprint" => FieldPhotoPrompt.prompt_fingerprint_sha256,
        "model_id" => squish_string(model_id),
        "canonical_component" => identifier(data["canonical_component"]),
        "manufacturer" => identifier(data["manufacturer"]),
        "model" => identifier(data["model"]),
        "subsystem" => data["subsystem"],
        "condition" => data["condition"],
        "visible_text" => project_visible_text(data["visible_text"]),
        "target_visible" => target_visible,
        "relevance_to_goal" => relevance_to_goal
      }
      trim_visible_text_to_budget!(payload)
      payload
    end

    # Job gate. persist! stays for a caller that already holds a known payload.
    # A previous observation on this row is left in place unless status is stored.
    def accept!(photo:, parsed:, model_id:, target_visible: nil, relevance_to_goal: nil)
      if photo.nil?
        return Acceptance.new(status: "unavailable", observation: nil, reason: "persistence_failure")
      end

      candidate = from_analysis(
        parsed: parsed, model_id: model_id,
        target_visible: target_visible, relevance_to_goal: relevance_to_goal
      )
      reason = rejection_reason(candidate)
      return Acceptance.new(status: "invalid", observation: nil, reason: reason) if reason

      sanitized = sanitize(candidate)
      return Acceptance.new(status: "invalid", observation: nil, reason: "invalid_shape") if sanitized.nil?

      photo.update!(visual_observation: sanitized)
      Acceptance.new(status: "stored", observation: sanitized, reason: nil)
    rescue StandardError
      Acceptance.new(status: "unavailable", observation: nil, reason: "persistence_failure")
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

    def squish_string(value)
      return nil unless value.is_a?(String)

      value.squish
    end

    def identifier(value)
      text = squish_string(value)
      return "UNKNOWN" if text.blank? || text.length > MAX_CHARS

      text
    end

    def project_visible_text(value)
      return value unless value.is_a?(Array)

      seen = {}
      items = []
      value.each do |item|
        text = squish_string(item)
        next if text.blank? || text.length > MAX_CHARS || seen[text]

        seen[text] = true
        items << text
        break if items.size >= MAX_VISIBLE_TEXT
      end
      items
    end

    def trim_visible_text_to_budget!(payload)
      list = payload["visible_text"]
      return unless list.is_a?(Array)

      list.pop while list.any? && JSON.generate(payload).bytesize > MAX_BYTES
    end

    def rejection_reason(candidate)
      return "invalid_enum" if invalid_enum?(candidate)
      return "over_budget" if JSON.generate(candidate).bytesize > MAX_BYTES
      return "invalid_shape" if sanitize(candidate).nil?

      nil
    end

    def invalid_enum?(candidate)
      return true unless candidate.is_a?(Hash)

      SUBSYSTEMS.exclude?(candidate["subsystem"]) ||
        CONDITIONS.exclude?(candidate["condition"]) ||
        invalid_relevance?(candidate["relevance_to_goal"])
    end

    def invalid_relevance?(value)
      return false if value.nil?
      return true unless value.is_a?(String)

      RELEVANCE.exclude?(value)
    end

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
