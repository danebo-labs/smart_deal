# frozen_string_literal: true

module Rag
  # Independent live-route flag. It is intentionally separate from the three
  # evidence-selector shadow/card switches.
  module StructuredEvidenceRouteFlag
    module_function

    def enabled?
      ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] == "true"
    end
  end
end
