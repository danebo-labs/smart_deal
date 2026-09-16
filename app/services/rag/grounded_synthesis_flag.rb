# frozen_string_literal: true

module Rag
  # Independent flag for the grounded-synthesis generation contract (gs-v1).
  # Default off unless ENV is the exact string "true". An empty/absent account
  # list means every account (including nil). A non-empty list is an optional
  # restrictor and is not used in production (D2, D13).
  module GroundedSynthesisFlag
    module_function

    def enabled?
      ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] == "true"
    end

    def enabled_for?(account)
      return false unless enabled?

      allowed = configured_account_ids
      return true if allowed.empty?

      id = account.respond_to?(:id) ? account.id : account
      return false if id.nil?

      allowed.include?(id.to_s)
    end

    def configured_account_ids
      ENV["RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS"].to_s.split(",").map(&:strip).compact_blank
    end
  end
end
