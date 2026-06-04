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

  BEDROCK_PRICING = {
    # Anthropic direct API — Batch (50% off standard). Used by bulk ingestion pipeline.
    # cache_read: 10% of base input; cache_creation: 125% of base input — both at batch rate.
    'claude-opus-4-7'                                  => { input: 0.0075,  output: 0.0375,  cache_read: 0.00075,  cache_creation: 0.009375 },
    'claude-sonnet-4-6'                                => { input: 0.0015,  output: 0.0075,  cache_read: 0.00015,  cache_creation: 0.001875 },
    # Explicit -batch suffix: emitted by IngestBatchResultsJob for correct rate attribution.
    'claude-opus-4-7-batch'                            => { input: 0.0075,  output: 0.0375,  cache_read: 0.00075,  cache_creation: 0.009375 },
    'claude-sonnet-4-6-batch'                          => { input: 0.0015,  output: 0.0075,  cache_read: 0.00015,  cache_creation: 0.001875 },
    # Anthropic direct API — Standard (non-batch). Used by CustomChunkingPipeline (sync web uploads).
    # Suffix -direct distinguishes direct-API rates from batch rates in analytics.
    'claude-opus-4-7-direct'                           => { input: 0.015,   output: 0.075,   cache_read: 0.0015,   cache_creation: 0.01875  },
    'claude-sonnet-4-6-direct'                         => { input: 0.003,   output: 0.015,   cache_read: 0.0003,   cache_creation: 0.00375  },
    'claude-haiku-4-5-20251001-direct'                 => { input: 0.0008,  output: 0.004,   cache_read: 0.00008,  cache_creation: 0.001    },
    # Claude 4.6 / 4.5 — Inference Profiles Globales (prices per 1K tokens, i.e. $/1M)
    'global.anthropic.claude-sonnet-4-6'               => { input: 0.003,  output: 0.015  },
    'global.anthropic.claude-opus-4-6-v1'              => { input: 0.005,  output: 0.025  },
    'global.anthropic.claude-haiku-4-5-20251001-v1:0'  => { input: 0.001,  output: 0.005  },
    # Amazon Nova Pro
    'us.amazon.nova-pro-v1:0'                          => { input: 0.00125, output: 0.00125 },
    # Legacy 4.5 (fallback)
    'global.anthropic.claude-sonnet-4-5-20250929-v1:0' => { input: 0.003,  output: 0.015  },
    'global.anthropic.claude-opus-4-5-20251101-v1:0'   => { input: 0.015,  output: 0.075  },
    'us.anthropic.claude-sonnet-4-5-20250929-v1:0'    => { input: 0.003,  output: 0.015  },
    'us.anthropic.claude-haiku-4-5-20251001-v1:0'      => { input: 0.0008, output: 0.004  },
    'us.anthropic.claude-opus-4-5-20251101-v1:0'       => { input: 0.015,  output: 0.075  },
    # Claude 3.x family (incl. US inference profiles)
    'anthropic.claude-3-7-sonnet-20250219-v1:0'        => { input: 0.003,   output: 0.015  },
    'anthropic.claude-3-5-sonnet-20241022-v2:0'        => { input: 0.003,   output: 0.015  },
    'us.anthropic.claude-3-5-sonnet-20241022-v2:0'     => { input: 0.003,   output: 0.015  },
    'us.anthropic.claude-3-5-haiku-20241022-v1:0'      => { input: 0.00025, output: 0.00125 },
    'anthropic.claude-3-5-sonnet-20240620-v1:0'        => { input: 0.003,   output: 0.015  },
    'anthropic.claude-3-sonnet-20240229-v1:0'          => { input: 0.003,   output: 0.015  },
    'anthropic.claude-3-haiku-20240307-v1:0'           => { input: 0.00025, output: 0.00125 },
    'amazon.titan-embed-text-v1'                       => { input: 0.0001,  output: 0.0    },
    'amazon.titan-embed-text-v2:0'                     => { input: 0.00002, output: 0.0    },
    'amazon.nova-2-multimodal-embeddings-v1:0'         => { input: 0.0006,  output: 0.0    },
    'default' => { input: 0.00025, output: 0.00125 } # Fallback to Haiku cost estimate
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
