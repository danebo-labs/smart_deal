# frozen_string_literal: true

class BedrockQuery < ApplicationRecord
  validates :model_id, :input_tokens, :output_tokens, presence: true
  validates :input_tokens, numericality: { greater_than: 0 }
  validates :output_tokens, numericality: { greater_than_or_equal_to: 0 }

  BEDROCK_PRICING = {
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
    'default' => { input: 0.00025, output: 0.00125 } # Fallback to Haiku cost estimate
  }.freeze

  def cost
    pricing = BEDROCK_PRICING[model_id] || BEDROCK_PRICING['default']
    input_cost  = (input_tokens  / 1000.0) * pricing[:input]
    output_cost = (output_tokens / 1000.0) * pricing[:output]
    (input_cost + output_cost).round(6)
  end
end
