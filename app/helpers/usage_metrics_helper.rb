# frozen_string_literal: true

# Single source of truth for home footer + dashboard daily cost breakdown.
# Values come from CostMetric.daily_snapshot / MetricsHelper#current_metrics.
module UsageMetricsHelper
  DAILY_USAGE_CHANNELS = [
    { label: "Consultas (Bedrock Haiku)", tokens: :today_tokens_query, cost: :today_cost_query, group: :query },
    { label: "Parse sync (Sonnet)", tokens: :today_tokens_anthropic_sonnet_direct, cost: :today_cost_anthropic_sonnet_direct, group: :parse_sync },
    { label: "Parse sync (Opus)", tokens: :today_tokens_anthropic_opus_direct, cost: :today_cost_anthropic_opus_direct, group: :parse_sync },
    { label: "Parse sync (Haiku)", tokens: :today_tokens_anthropic_haiku_direct, cost: :today_cost_anthropic_haiku_direct, group: :parse_sync },
    { label: "Parse batch (Sonnet)", tokens: :today_tokens_anthropic_sonnet_batch, cost: :today_cost_anthropic_sonnet_batch, group: :parse_batch },
    { label: "Parse batch (Opus)", tokens: :today_tokens_anthropic_opus_batch, cost: :today_cost_anthropic_opus_batch, group: :parse_batch },
    { label: "Embeddings (Nova)", tokens: :today_tokens_embed, cost: :today_cost_embed, group: :embed }
  ].freeze

  def daily_usage_channel_rows(metrics)
    DAILY_USAGE_CHANNELS.map do |row|
      {
        label:  row[:label],
        tokens: metrics[row[:tokens]].to_i,
        cost:   metrics[row[:cost]].to_f,
        group:  row[:group]
      }
    end
  end

  def daily_usage_total_row(metrics)
    {
      label:  "Total hoy",
      tokens: metrics[:today_tokens].to_i,
      cost:   metrics[:today_cost].to_f,
      group:  :total,
      strong: true
    }
  end
end
