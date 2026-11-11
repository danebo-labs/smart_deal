# frozen_string_literal: true

module Rag
  # Production web and job processes refuse to boot on the Haiku 4.5 path.
  class DirectInferenceBoot
    def self.direct_generation?(env = ENV)
      env.fetch("RAG_COMPANION_GENERATION", "direct").to_s.strip == "direct"
    end

    def self.check!(env = ENV)
      missing = []
      missing << "BEDROCK_INFERENCE=blocked" unless InferencePolicy.blocked?(env, default: true)
      missing << "RAG_COMPANION_GENERATION=direct" unless direct_generation?(env)
      return if missing.empty?

      raise "direct inference boot refused: #{missing.join(", ")}"
    end
  end
end
