# frozen_string_literal: true

require "test_helper"

class AccountActivityChartServiceTest < ActiveSupport::TestCase
  setup do
    BedrockQuery.destroy_all
    @account = accounts(:legacy)
    @user = users(:one)
    @today = Date.new(2026, 9, 11)
  end

  def create_query!(user:, created_at:, source: :query, account: @account)
    BedrockQuery.create!(
      account_id: account.id,
      user_id: user.id,
      model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      input_tokens: 100,
      output_tokens: 50,
      latency_ms: 400,
      source: source,
      created_at: created_at
    )
  end

  test "one series per user, bucketed by day" do
    other_user = User.create!(email: "colleague@example.com", password: "password123", account: @account)

    create_query!(user: @user, created_at: @today.in_time_zone.noon)
    create_query!(user: @user, created_at: @today.in_time_zone.noon)
    create_query!(user: other_user, created_at: @today.in_time_zone.noon)

    result = AccountActivityChartService.new(account_id: @account.id, today: @today).call

    labels = result[:datasets].pluck(:label)
    assert_includes labels, @user.email
    assert_includes labels, other_user.email
    assert_equal 2, result[:datasets].size
    assert_equal 3, result[:total]
  end

  test "ignores rows that are not chat queries" do
    create_query!(user: @user, created_at: @today.in_time_zone.noon, source: :ingestion_parse)
    create_query!(user: @user, created_at: @today.in_time_zone.noon, source: :ingestion_embed)

    result = AccountActivityChartService.new(account_id: @account.id, today: @today).call

    assert_equal 0, result[:total]
    assert_empty result[:datasets]
  end

  test "excludes rows from another account" do
    other_account = accounts(:climb)
    other_user = users(:two)
    create_query!(user: other_user, created_at: @today.in_time_zone.noon, account: other_account)

    result = AccountActivityChartService.new(account_id: @account.id, today: @today).call

    assert_equal 0, result[:total]
    assert_empty result[:datasets]
  end

  test "days without activity stay at zero and the window has 30 points" do
    create_query!(user: @user, created_at: @today.in_time_zone.noon)

    result = AccountActivityChartService.new(account_id: @account.id, today: @today).call

    assert_equal 30, result[:labels].length
    series = result[:datasets].first
    assert_equal 30, series[:data].length
    assert_equal 1, series[:data].last
    assert_equal 0, series[:data].first
  end

  test "per_user rows report window and today counts plus last activity" do
    create_query!(user: @user, created_at: (@today - 5.days).in_time_zone.noon)
    create_query!(user: @user, created_at: @today.in_time_zone.noon)

    result = AccountActivityChartService.new(account_id: @account.id, today: @today).call
    row = result[:per_user].find { |r| r[:email] == @user.email }

    assert_equal 2, row[:window_queries]
    assert_equal 1, row[:today_queries]
    assert_equal @today, row[:last_activity].to_date
  end
end
