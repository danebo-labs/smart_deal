# frozen_string_literal: true

class CostMetric < ApplicationRecord
  enum :metric_type, {
    daily_tokens: 0,
    daily_cost: 1,
    daily_queries: 2,
    aurora_acu_avg: 3,
    s3_documents_count: 4,
    s3_total_size: 5,
    daily_tokens_query: 6,
    daily_tokens_parse: 7,
    daily_tokens_embed: 8,
    daily_cost_query: 9,
    daily_cost_parse: 10,
    daily_cost_embed: 11,
    daily_cache_hits: 12,
    daily_tokens_saved: 13
  }

  # Ensure metric_type always returns a symbol
  def metric_type
    value = read_attribute(:metric_type)
    value&.to_sym
  end

  validates :date, presence: true, uniqueness: { scope: :metric_type }
  validates :metric_type, presence: true
  validates :value, presence: true, numericality: true

  scope :current_month, -> { where(date: Date.current.beginning_of_month..Date.current) }
  scope :last_month, lambda {
    last_month_start = 1.month.ago.beginning_of_month
    last_month_end = 1.month.ago.end_of_month
    where(date: last_month_start..last_month_end)
  }
  scope :last_30_days, -> { where(date: 30.days.ago..Date.current) }

  # Metric types fetched together for the home footer / metrics-broadcast view.
  # Order is irrelevant — the query plucks all rows matching this list in a
  # single round-trip and the helper maps them into the view-shape hash below.
  TRACKED_TYPES_FOR_SNAPSHOT = %i[
    daily_tokens daily_cost daily_queries
    daily_tokens_query daily_tokens_parse daily_tokens_embed
    daily_cost_query daily_cost_parse daily_cost_embed
    daily_cache_hits daily_tokens_saved
    aurora_acu_avg s3_documents_count s3_total_size
  ].freeze

  # Returns the view-shape hash consumed by `home/_chat_usage_footer_metrics`
  # and `MetricsHelper#current_metrics`. Replaces 14 individual `find_by` calls
  # (one per metric_type) with a single SELECT.
  #
  # @param date [Date] day to snapshot — defaults to today
  # @return [Hash] view-shape symbol-keyed hash
  def self.daily_snapshot(date = Date.current)
    raw = where(date: date, metric_type: TRACKED_TYPES_FOR_SNAPSHOT).pluck(:metric_type, :value)
    # `pluck(:metric_type, :value)` may return symbol or string keys depending
    # on Rails enum exposure — normalize defensively.
    by_type = raw.each_with_object({}) { |(t, v), acc| acc[t.to_sym] = v }

    s3_bytes = by_type[:s3_total_size] || 0
    {
      today_tokens:        by_type[:daily_tokens]        || 0,
      today_cost:          by_type[:daily_cost]          || 0,
      today_queries:       by_type[:daily_queries]       || 0,
      today_tokens_query:  by_type[:daily_tokens_query]  || 0,
      today_tokens_parse:  by_type[:daily_tokens_parse]  || 0,
      today_tokens_embed:  by_type[:daily_tokens_embed]  || 0,
      today_cost_query:    by_type[:daily_cost_query]    || 0,
      today_cost_parse:    by_type[:daily_cost_parse]    || 0,
      today_cost_embed:    by_type[:daily_cost_embed]    || 0,
      today_cache_hits:    by_type[:daily_cache_hits]    || 0,
      today_tokens_saved:  by_type[:daily_tokens_saved]  || 0,
      aurora_acu:          by_type[:aurora_acu_avg]      || 0,
      s3_documents:        by_type[:s3_documents_count]  || 0,
      s3_size_mb:          (s3_bytes / 1.megabyte.to_f).round(2),
      s3_size_gb:          (s3_bytes / 1.gigabyte.to_f).round(2)
    }
  end

  def self.total_for_month(metric_type)
    current_month.where(metric_type: metric_type).sum(:value)
  end

  def self.avg_for_month(metric_type)
    current_month.where(metric_type: metric_type).average(:value) || 0
  end

  def self.total_for_last_month(metric_type)
    last_month.where(metric_type: metric_type).sum(:value)
  end

  def self.avg_for_last_month(metric_type)
    last_month.where(metric_type: metric_type).average(:value) || 0
  end
end
