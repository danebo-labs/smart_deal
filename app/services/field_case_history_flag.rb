# frozen_string_literal: true

# Case history for the personal web workspace. Off unless
# FIELD_CASE_HISTORY_ENABLED is the exact string "true".
# A shared session keeps today's workspace path and does not use these tables.
module FieldCaseHistoryFlag
  module_function

  def enabled?(shared_session: SharedSession::ENABLED)
    return false if shared_session

    ENV["FIELD_CASE_HISTORY_ENABLED"] == "true"
  end
end
