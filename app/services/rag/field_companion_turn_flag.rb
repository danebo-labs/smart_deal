# frozen_string_literal: true

module Rag
  # Switch for reading the active episode into the turn text.
  # Default OFF. Phase 1 does not read it.
  module FieldCompanionTurnFlag
    module_function

    def enabled?
      ENV["FIELD_COMPANION_TURN_ENABLED"] == "true"
    end
  end
end
