# frozen_string_literal: true

module Rag
  # Raw technician text in PILOT_AUDIT and TURN_EVIDENCE.
  # The flag must be the string "true". An empty account list keeps that
  # capture global. A list restricts the raw text to those account ids.
  # An unknown account fails closed when a list is set. Hashes and
  # operational fields stay either way. Credentials are not added here.
  module PilotAuditCapture
    FLAG = "PILOT_AUDIT_CAPTURE"
    ACCOUNTS = "PILOT_AUDIT_CAPTURE_ACCOUNT_IDS"

    module_function

    def include_text?(account_id)
      return false unless ENV[FLAG] == "true"

      allowed = account_ids
      return true if allowed.empty?
      return false if account_id.nil?

      allowed.include?(account_id.to_s)
    end

    def account_ids
      ENV[ACCOUNTS].to_s.split(",").filter_map { |item| item.strip.presence }
    end
  end
end
