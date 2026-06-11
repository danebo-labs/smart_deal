# frozen_string_literal: true

module Rag
  # Deterministic stop-work checklist answer (benchmark plan Fase 7).
  #
  # Two sections with fixed localized headings:
  #
  #   Precauciones e inspecciones
  #   - <inspection/safety-warning action>: <documented result>
  #
  #   Detención obligatoria con evidencia explícita
  #   Disparador: <STOP_WORK_TRIGGER, verbatim>
  #   Acción obligatoria: <STOP_WORK_REQUIRED_ACTION, verbatim>
  #
  # Only STOP_WORK_CONDITION records (which carry a complete trigger/action
  # pair by parser contract) feed the mandatory section. A record without the
  # pair can never be promoted.
  class StopWorkRenderer < DeterministicRenderer
    PRECAUTION_TYPES = %w[INSPECTION_CHECK SAFETY_WARNING].freeze

    def generation_mode
      "deterministic_stop_work"
    end

    private

    def number_of_results
      FULL_SCOPE_CANDIDATES
    end

    def select_records(ledger)
      mandatory   = ledger.records.select(&:stop_work?)
      precautions = ledger.records.select { |record| PRECAUTION_TYPES.include?(record.type) }
      return [] if mandatory.empty? || precautions.empty?

      precautions + mandatory
    end

    def render(records)
      mandatory   = records.select(&:stop_work?)
      precautions = records.reject(&:stop_work?)

      precaution_lines = precautions.map do |record|
        if record.expected_result == "DATA_NOT_AVAILABLE"
          "- #{record.action}"
        else
          "- #{record.action}: #{record.expected_result}"
        end
      end

      mandatory_blocks = mandatory.map do |record|
        [
          "#{label(:trigger_label)}: #{record.stop_trigger}",
          "#{label(:mandatory_action_label)}: #{record.stop_action}"
        ].join("\n")
      end

      [
        label(:precautions_heading),
        precaution_lines.join("\n"),
        "",
        label(:mandatory_heading),
        mandatory_blocks.join("\n\n")
      ].join("\n")
    end
  end
end
