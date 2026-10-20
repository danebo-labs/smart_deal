# frozen_string_literal: true

module Rag
  # FC-D12. Default off. A needle still comes from the retrieved chunk.
  # An abbreviated title is not a conflicting model. Proven correspondence
  # reads one confirmed catalog entry bound by the authorized document UID
  # and URI. A pin alone does not make that manual applicable.
  module DocumentIdentityScopeFlag
    module_function

    def enabled?
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] == "true"
    end
  end
end
