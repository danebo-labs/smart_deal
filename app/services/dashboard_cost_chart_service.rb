# frozen_string_literal: true

# Builds calendar-month line-chart payload for the dashboard (one series per LLM channel).
class DashboardCostChartService
  CHART_COLORS = %w[
    #2563eb #dc2626 #16a34a #9333ea #ea580c #0891b2 #ca8a04
  ].freeze

  def initialize(month: Date.current)
    @month_start = month.beginning_of_month
    @month_end = month.end_of_month
    @days = (@month_start..@month_end).to_a
  end

  def call
    channels = UsageMetricsHelper.chart_channels
    metric_types = channels.pluck(:metric_type)

    rows = CostMetric.where(date: @month_start..@month_end, metric_type: metric_types)
                     .pluck(:date, :metric_type, :value)

    by_date = rows.each_with_object({}) do |(date, metric_type, value), acc|
      acc[date] ||= {}
      acc[date][metric_type.to_sym] = value.to_f
    end

    active = channels.select do |channel|
      @days.sum { |day| by_date.dig(day, channel[:metric_type]).to_f }.positive?
    end

    {
      title: I18n.l(@month_start, format: "%B %Y"),
      labels: @days.map { |d| d.day.to_s },
      datasets: active.each_with_index.map do |channel, idx|
        {
          label: channel[:label],
          data: @days.map { |day| by_date.dig(day, channel[:metric_type]).to_f.round(4) },
          borderColor: CHART_COLORS[idx % CHART_COLORS.length],
          backgroundColor: "#{CHART_COLORS[idx % CHART_COLORS.length]}33",
          tension: 0.25,
          fill: false
        }
      end
    }
  end
end
