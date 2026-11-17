# frozen_string_literal: true

# Case history for the authenticated technician's own web workspace.
# On whether FIELD_CASE_HISTORY_ENABLED is absent, "false", or any other
# inherited value. A shared session keeps today's workspace path and does
# not use these tables.
module FieldCaseHistoryFlag
  module_function

  def enabled?(shared_session: SharedSession::ENABLED)
    !shared_session
  end
end
