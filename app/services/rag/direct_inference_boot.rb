# frozen_string_literal: true

module Rag
  # Production web and job processes refuse to boot on the Haiku 4.5 path.
  class DirectInferenceBoot
    def self.check!(env = ENV)
      missing = []
      missing << "BEDROCK_INFERENCE=blocked" unless env["BEDROCK_INFERENCE"] == "blocked"
      missing << "RAG_COMPANION_GENERATION=direct" unless env["RAG_COMPANION_GENERATION"] == "direct"
      return if missing.empty?

      raise "direct inference boot refused: #{missing.join(", ")}"
    end
  end
end
