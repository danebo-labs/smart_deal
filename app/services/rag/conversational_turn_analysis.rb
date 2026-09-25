# frozen_string_literal: true

module Rag
  # Immutable semantic perception for one turn. P1 does not write this object anywhere.
  ConversationalTurnAnalysis = Data.define(:relation, :mentions, :refers_to, :ambiguous) do
    def initialize(relation:, mentions: [], refers_to: [], ambiguous: false)
      super(
        relation: relation.to_s,
        mentions: Array(mentions).map { |item| item.transform_keys(&:to_s).freeze }.freeze,
        refers_to: Array(refers_to).map { |item| item.transform_keys(&:to_s).freeze }.freeze,
        ambiguous: ambiguous == true
      )
      freeze
    end
  end
end
