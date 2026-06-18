# frozen_string_literal: true

class BedrockQuery < ApplicationRecord
  validates :model_id, :input_tokens, :output_tokens, presence: true
  validates :input_tokens, numericality: { greater_than: 0 }
  validates :output_tokens, numericality: { greater_than_or_equal_to: 0 }

  enum :source, {
    query:            "query",
    ingestion_parse:  "ingestion_parse",
    ingestion_embed:  "ingestion_embed"
  }, default: :query

  scope :estimated_tokens, -> { where(token_source: "estimated") }

  # Rows with token_source "estimated" reconstruct input from observable
  # citations (Bedrock R&G exposes no usage block). Current reconciliation
  # measured ~3.8% average cost undercount, with larger hybrid-query outliers.
  # #cost is operational diagnosis there, never invoice truth. NULL = legacy.
  def estimated_tokens?
    token_source == "estimated"
  end

  BEDROCK_PRICING = {
    # Anthropic Batch API (50% off standard). Opus 4.7/4.8: $5/$25 standard → batch $2.50/$12.50
    # cache_read: 10% of base input; cache_creation: 125% of base input — both at batch rate.
    'claude-opus-4-7'                                  => { input: 0.0025,  output: 0.0125,  cache_read: 0.00025,  cache_creation: 0.003125 },
    'claude-opus-4-7-batch'                            => { input: 0.0025,  output: 0.0125,  cache_read: 0.00025,  cache_creation: 0.003125 },
    'claude-opus-4-8-batch'                            => { input: 0.0025,  output: 0.0125,  cache_read: 0.00025,  cache_creation: 0.003125 },
    'claude-sonnet-4-6-batch'                          => { input: 0.0015,  output: 0.0075,  cache_read: 0.00015,  cache_creation: 0.001875 },
    # Anthropic Direct API. Suffix -direct emitted by ClaudeChunkingClient / IngestBatchResultsJob.
    'claude-opus-4-7-direct'                           => { input: 0.005,   output: 0.025,   cache_read: 0.0005,   cache_creation: 0.00625  },
    'claude-opus-4-8-direct'                           => { input: 0.005,   output: 0.025,   cache_read: 0.0005,   cache_creation: 0.00625  },
    'claude-sonnet-4-6-direct'                         => { input: 0.003,   output: 0.015,   cache_read: 0.0003,   cache_creation: 0.00375  },
    'claude-haiku-4-5-20251001-direct'                 => { input: 0.001,   output: 0.005,   cache_read: 0.0001,   cache_creation: 0.00125  },
    # Bedrock Inference Profiles (global. ~10% cheaper than us.)
    'global.anthropic.claude-opus-4-6-v1'              => { input: 0.005,  output: 0.025  },
    'global.anthropic.claude-haiku-4-5-20251001-v1:0'  => { input: 0.001,  output: 0.005  },
    'us.anthropic.claude-haiku-4-5-20251001-v1:0'      => { input: 0.0011, output: 0.0055 },
    # Embeddings
    'amazon.titan-embed-text-v2:0'                     => { input: 0.00002, output: 0.0    },
    'amazon.nova-2-multimodal-embeddings-v1:0'         => { input: 0.0006,  output: 0.0    },
    'default' => { input: 0.00025, output: 0.00125 }
  }.freeze

  def cost
    pricing = BEDROCK_PRICING[model_id] ||
              BEDROCK_PRICING.each_with_object(nil) { |(k, v), _| break v if k != 'default' && model_id.to_s.start_with?(k) } ||
              BEDROCK_PRICING['default']

    input_cost          = (input_tokens.to_i          / 1000.0) * pricing[:input]
    output_cost         = (output_tokens.to_i          / 1000.0) * pricing[:output]
    cache_read_cost     = (cache_read_tokens.to_i      / 1000.0) * (pricing[:cache_read]     || pricing[:input] * 0.1)
    cache_creation_cost = (cache_creation_tokens.to_i  / 1000.0) * (pricing[:cache_creation] || pricing[:input] * 1.25)
    (input_cost + output_cost + cache_read_cost + cache_creation_cost).round(6)
  end
end
