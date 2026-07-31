# frozen_string_literal: true

module Rag
  # Independent flag for the deterministic partial-abstention contract.
  module PartialAbstentionContractFlag
    module_function

    def enabled?
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] == "true"
    end
  end
end
