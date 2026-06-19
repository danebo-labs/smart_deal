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

  # Rows whose cost lands on the AWS Bedrock invoice. The `-direct` / `-batch`
  # suffixes are Anthropic Direct/Batch API spend and must NOT be reconciled
  # against the AWS bill. Native Bedrock model/profile ids are the billable set.
  AWS_BEDROCK_MODEL_PREFIXES = %w[
    global.anthropic us.anthropic eu.anthropic apac.anthropic amazon.
  ].freeze

  scope :aws_bedrock_billable, lambda {
    where(AWS_BEDROCK_MODEL_PREFIXES.map { "model_id LIKE ?" }.join(" OR "),
          *AWS_BEDROCK_MODEL_PREFIXES.map { |p| "#{p}%" })
  }

  # AWS Cost Explorer/CUR buckets usage by UTC calendar day. The live metrics
  # rollup buckets by Time.zone (America/Santiago) for technician-facing "today";
  # invoice reconciliation must use this UTC window instead.
  scope :for_utc_day, ->(date) { where(created_at: Time.utc(date.year, date.month, date.day).all_day) }

  # Reconciliation report for one UTC day, grouped by Bedrock model/profile.
  # Splits input vs output cost (AWS bills them as separate UsageTypes) and
  # flags the estimated-token caveat. cache_read_tokens is nil on the
  # retrieve_and_generate path, so any Bedrock prompt-cache discount is NOT
  # reflected here — estimated rows skew high when caching is active.
  # @param date [Date] UTC calendar date
  # @return [Hash] { date:, rows: [...], total_cost:, estimated_share: }
  def self.aws_reconciliation(date)
    rows = aws_bedrock_billable.for_utc_day(date)
             .group_by(&:model_id)
             .map do |mid, rs|
      pricing = rs.first.pricing_for(mid)
      in_cost  = rs.sum { |r| (r.input_tokens.to_i  / 1000.0) * pricing[:input] }
      out_cost = rs.sum { |r| (r.output_tokens.to_i / 1000.0) * pricing[:output] }
      {
        model_id:      mid,
        count:         rs.size,
        input_tokens:  rs.sum { |r| r.input_tokens.to_i },
        output_tokens: rs.sum { |r| r.output_tokens.to_i },
        input_cost:    in_cost.round(6),
        output_cost:   out_cost.round(6),
        cost:          (in_cost + out_cost).round(6),
        estimated:     rs.count(&:estimated_tokens?)
      }
    end
    total = rows.sum { |r| r[:cost] }
    est   = rows.sum { |r| r[:estimated] }
    {
      date:            date,
      rows:            rows.sort_by { |r| -r[:cost] },
      total_cost:      total.round(6),
      estimated_share: rows.sum { |r| r[:count] }.then { |n| n.zero? ? 0.0 : (est.to_f / n).round(3) }
    }
  end

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

  def pricing_for(mid = model_id)
    BEDROCK_PRICING[mid] ||
      BEDROCK_PRICING.each_with_object(nil) { |(k, v), _| break v if k != 'default' && mid.to_s.start_with?(k) } ||
      BEDROCK_PRICING['default']
  end

  def cost
    pricing = pricing_for

    input_cost          = (input_tokens.to_i          / 1000.0) * pricing[:input]
    output_cost         = (output_tokens.to_i          / 1000.0) * pricing[:output]
    cache_read_cost     = (cache_read_tokens.to_i      / 1000.0) * (pricing[:cache_read]     || pricing[:input] * 0.1)
    cache_creation_cost = (cache_creation_tokens.to_i  / 1000.0) * (pricing[:cache_creation] || pricing[:input] * 1.25)
    (input_cost + output_cost + cache_read_cost + cache_creation_cost).round(6)
  end
end
