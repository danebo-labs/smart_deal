# frozen_string_literal: true

module Rag
  # Deterministic stop-work answer (benchmark plan Fase 7), in prose (CG-D19).
  #
  # Two paragraphs opened by a fixed localized sentence each, no headings and
  # no field labels:
  #
  #   <precautions_intro>
  #   <inspection/safety-warning action>: <documented result>
  #
  #   <mandatory_intro>
  #   <stop_entry: STOP_WORK_TRIGGER and STOP_WORK_REQUIRED_ACTION, verbatim>
  #
  # Only STOP_WORK_CONDITION records (which carry a complete trigger/action
  # pair by parser contract) feed the mandatory paragraph. A record without
  # the pair can never be promoted.
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
        if record.expected_result == DATA_NOT_AVAILABLE
          sentence(record.action)
        else
          sentence(copy(:precaution_entry, action: record.action, result: record.expected_result))
        end
      end

      mandatory_lines = mandatory.map do |record|
        sentence(copy(:stop_entry, trigger: record.stop_trigger, action: record.stop_action))
      end

      [
        copy(:precautions_intro),
        precaution_lines.join("\n"),
        "",
        copy(:mandatory_intro),
        mandatory_lines.join("\n\n")
      ].join("\n")
    end
  end
end
