# frozen_string_literal: true

module Rag
  # Immutable semantic perception for one turn. P1 does not write this object anywhere.
  ConversationalTurnAnalysis = Data.define(
    :relation, :mentions, :refers_to, :ambiguous,
    :dialogue_function, :technical_facts, :technical_observations, :pending_answer
  ) do
    def initialize(relation:, mentions: [], refers_to: [], ambiguous: false,
                   dialogue_function: nil, technical_facts: [], technical_observations: [], pending_answer: nil)
      super(
        relation: relation.to_s,
        mentions: Array(mentions).map { |item| item.transform_keys(&:to_s).freeze }.freeze,
        refers_to: Array(refers_to).map { |item| item.transform_keys(&:to_s).freeze }.freeze,
        ambiguous: ambiguous == true,
        dialogue_function: dialogue_function&.to_s,
        technical_facts: Array(technical_facts).map { |item| item.is_a?(Hash) ? item.transform_keys(&:to_s).freeze : item }.freeze,
        technical_observations: Array(technical_observations).map(&:to_s).freeze,
        pending_answer: pending_answer&.to_s
      )
      freeze
    end
  end
end
