# frozen_string_literal: true

module Rag
  # Retrieval-safety input for one photo turn. It is not an episode fact
  # and it is not a document-compatibility decision.
  class EquipmentIdentity
    attr_reader :manufacturer, :needles, :facts

    def initialize(manufacturer:, needles:, facts:)
      @manufacturer = manufacturer
      @needles = Array(needles).map(&:to_s).freeze
      @facts = Array(facts).map { |fact| fact.to_h.stringify_keys.freeze }.freeze
      freeze
    end
  end
end
