# frozen_string_literal: true

# Builds the query-volume chart payload for /actividad: one stacked bar series
# per user, rolling 30-day window ending today (not calendar month — see
# dashboard_demo_actividad plan). Pure counts from BedrockQuery, never touches
# CostMetric/#cost — this is what keeps the page structurally free of "$".
class AccountActivityChartService
  WINDOW_DAYS = 30

  CHART_COLORS = %w[
    #2563eb #dc2626 #16a34a #9333ea #ea580c #0891b2 #ca8a04
  ].freeze

  def initialize(account_id:, today: Time.zone.today)
    @account_id = account_id
    @today = today
    @window_start = today - (WINDOW_DAYS - 1).days
    @days = (@window_start..@today).to_a
  end

  def call
    rows = BedrockQuery.query
                        .where(account_id: @account_id, created_at: @window_start.beginning_of_day..@today.end_of_day)
                        .pluck(:user_id, :created_at)

    users = User.where(account_id: @account_id).pluck(:id, :email).to_h

    by_user_day = Hash.new(0)
    per_user_counts = Hash.new(0)
    per_user_today = Hash.new(0)
    last_activity = {}

    rows.each do |user_id, created_at|
      date = created_at.in_time_zone.to_date
      by_user_day[[ user_id, date ]] += 1
      per_user_counts[user_id] += 1
      per_user_today[user_id] += 1 if date == @today
      last_activity[user_id] = created_at if last_activity[user_id].nil? || created_at > last_activity[user_id]
    end

    # Legacy BedrockQuery rows can have user_id nil; Array#sort raises
    # ArgumentError on Integer vs nil, which 500'd /actividad in production.
    active_user_ids = per_user_counts.keys.sort_by { |id| [ id.nil? ? 1 : 0, id.to_i ] }

    {
      labels: @days.map { |d| I18n.l(d, format: "%d/%m") },
      datasets: active_user_ids.each_with_index.map do |user_id, idx|
        {
          label: label_for(user_id, users),
          data: @days.map { |d| by_user_day[[ user_id, d ]] },
          backgroundColor: CHART_COLORS[idx % CHART_COLORS.length]
        }
      end,
      per_user: active_user_ids.map do |user_id|
        {
          email: label_for(user_id, users),
          window_queries: per_user_counts[user_id],
          today_queries: per_user_today[user_id],
          last_activity: last_activity[user_id]
        }
      end,
      total: rows.size,
      today: per_user_today.values.sum
    }
  end

  private

  def label_for(user_id, users)
    users[user_id].presence || (user_id.nil? ? "Sin usuario" : "Usuario ##{user_id}")
  end
end
