# frozen_string_literal: true

module Rag
  # Default-off gate. The request path stays serial and this class performs no retrieval.
  class ExplicitRetrieveOverlap
    ENV_KEY = "HAIKU_EXPLICIT_RETRIEVE_OVERLAP"

    def self.enabled?
      ENV[ENV_KEY] == "1"
    end

    def self.decision(before:, after:, relation: nil, ambiguous: false, deixis: false, photo_scope_changed: false)
      return "off" unless enabled?
      return "discarded" if ambiguous || deixis || photo_scope_changed
      return "discarded" if %w[switch correct].include?(relation.to_s)
      return "discarded" unless fingerprint(before) == fingerprint(after)

      "reused"
    end

    def self.fingerprint(fields)
      {
        equipment: fields[:equipment],
        component_span: fields[:component_span],
        fault: fields[:fault],
        constraints: fields[:constraints]
      }
    end
  end
end
