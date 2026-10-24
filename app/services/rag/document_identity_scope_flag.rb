# frozen_string_literal: true

module Rag
  # FC-D12. Absent or blank enables the scope. The explicit string "false"
  # is the kill switch. Any other string stays off. A needle still comes
  # from the retrieved chunk.
  # An abbreviated title is not a conflicting model. Proven correspondence
  # reads one confirmed catalog entry bound by the authorized document UID
  # and URI. A pin alone does not make that manual applicable.
  module DocumentIdentityScopeFlag
    module_function

    def enabled?
      value = ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"]
      return true if value.nil? || value.strip.empty?

      value == "true"
    end
  end
end
