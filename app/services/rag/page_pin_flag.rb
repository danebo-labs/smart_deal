# frozen_string_literal: true

module Rag
  # Independent live-route flag, same pattern as StructuredEvidenceRouteFlag.
  module PagePinFlag
    module_function

    def enabled?
      ENV["RAG_PAGE_PIN_ENABLED"] == "true"
    end
  end
end
