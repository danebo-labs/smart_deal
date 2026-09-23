# frozen_string_literal: true

module Rag
  # FC-D12. Default off. On is not enough: DocumentIdentityScope stays on the
  # current path until the catalog loads and at least one entry is confirmed
  # with a printed mark (evidence_page and evidence_text).
  module DocumentIdentityScopeFlag
    module_function

    def enabled?
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] == "true"
    end
  end
end
