# frozen_string_literal: true

# KB embedding model used for cost attribution on ingestion_embed rows.
# Matches the model configured on the Bedrock Knowledge Base (Titan Text v2, 1024-dim).
module BedrockEmbeddingModel
  DEFAULT_MODEL_ID = "amazon.titan-embed-text-v2:0"

  # AWS Bedrock on-demand: $0.02 / 1M input tokens (us-east-1, Titan Text Embeddings V2).
  # Stored per 1K tokens to match BedrockQuery::BEDROCK_PRICING.
  INPUT_PRICE_PER_1K = 0.00002

  def self.model_id
    raw = ENV["BEDROCK_EMBEDDING_MODEL_ID"].presence ||
          Rails.application.credentials.dig(:bedrock, :embedding_model_id) ||
          DEFAULT_MODEL_ID
    normalize_id(raw)
  end

  def self.normalize_id(raw)
    id = raw.to_s.strip
    return DEFAULT_MODEL_ID if id.blank?

    # Accept full foundation-model ARNs from KB console / deploy config.
    if id.include?("foundation-model/")
      id.split("foundation-model/").last
    else
      id
    end
  end
end
