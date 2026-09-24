# frozen_string_literal: true

module Rag
  # FC-D12. Default off. The query path labels retrieved chunks. It does not
  # read DocumentIdentityCatalog or config/document_identities.yml.
  module DocumentIdentityScopeFlag
    module_function

    def enabled?
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] == "true"
    end
  end
end
