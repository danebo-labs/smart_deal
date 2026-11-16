# frozen_string_literal: true

module Rag
  # Raw technician text in PILOT_AUDIT and TURN_EVIDENCE.
  # The flag must be the string "true". It covers every account. Account id
  # lists are not a gate. The durable trace stores the same text whether or
  # not this log line is enabled. Credentials are not added here.
  module PilotAuditCapture
    FLAG = "PILOT_AUDIT_CAPTURE"

    module_function

    def include_text?(_account_id = nil)
      ENV[FLAG] == "true"
    end
  end
end
