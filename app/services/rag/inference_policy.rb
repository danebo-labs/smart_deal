# frozen_string_literal: true

module Rag
  # Fail-closed switch for this cut. Retrieve and the companion rerank stay.
  # Every other Bedrock inference call stops before the SDK.
  class InferencePolicy
    class BedrockInferenceBlocked < BedrockRagService::BedrockServiceError; end

    ALLOWED = %w[agent_runtime.retrieve companion_candidate_order.rerank].freeze

    def self.blocked?(env = ENV, default: Rails.env.production?)
      value = env["BEDROCK_INFERENCE"]
      value.nil? ? default : value == "blocked"
    end

    def self.check!(operation:, model_id: nil)
      return unless blocked?
      return if ALLOWED.include?(operation.to_s)

      raise BedrockInferenceBlocked, "bedrock_inference_blocked:#{operation}:#{model_id}"
    end
  end
end
