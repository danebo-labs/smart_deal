# frozen_string_literal: true

module Rag
  # FC-D12. Default off. On is not enough: DocumentIdentityScope stays on the
  # current path until every general-corpus entry is confirmed.
  module DocumentIdentityScopeFlag
    module_function

    def enabled?
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] == "true"
    end
  end
end
