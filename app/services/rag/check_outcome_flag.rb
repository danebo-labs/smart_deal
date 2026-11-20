# frozen_string_literal: true

module Rag
  # Stage 1 of docs/field_companion/DISENO_FIELD_COMPANION_20261119.md.
  # Enables Rag::CheckOutcome, the single pending-question writer
  # (PendingQuestion.from_publication) and the "Estado de la comprobación"
  # block. Off unless the exact string "true" is set, so a deploy changes
  # nothing until the flag is authorized. Off is the previous behavior.
  module CheckOutcomeFlag
    module_function

    def enabled?
      ENV["FIELD_CHECK_OUTCOME"] == "true"
    end
  end
end
