# frozen_string_literal: true

module Rag
# Switch for reading the active episode into the turn text.
# Absent or blank enables it. The explicit string "false" is the kill switch.
# Any other string stays off.
module FieldCompanionTurnFlag
  module_function

  def enabled?
    value = ENV["FIELD_COMPANION_TURN_ENABLED"]
    return true if value.nil? || value.strip.empty?

    value == "true"
  end
end
end
