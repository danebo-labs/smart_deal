# frozen_string_literal: true

require 'test_helper'

class CostMetricTest < ActiveSupport::TestCase
  # No fixtures for this model - tests create their own specific data
  # This avoids conflicts and makes tests more explicit and controllable

  teardown do
    ActiveRecord::Base.connection_pool.disconnect!
  end

  test 'requires date, metric_type, and value' do
    I18n.with_locale(:en) do
      metric = CostMetric.new

      assert_not metric.valid?
      assert_includes metric.errors[:date], "can't be blank"
      assert_includes metric.errors[:metric_type], "can't be blank"
      assert_includes metric.errors[:value], "can't be blank"
    end
  end

  test 'enforces uniqueness of date + metric_type' do
    CostMetric.create!(
      date: Time.zone.today,
      metric_type: :daily_tokens,
      value: 100
    )

    duplicate = CostMetric.new(
      date: Time.zone.today,
      metric_type: :daily_tokens,
      value: 50
    )

    I18n.with_locale(:en) do
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:date], 'has already been taken'
    end
  end

  test '.total_for_month sums values correctly' do
    travel_to(Time.zone.local(2026, 6, 15)) do
      CostMetric.create!(
        date: Date.current.beginning_of_month,
        metric_type: :daily_tokens,
        value: 100
      )
      CostMetric.create!(
        date: Date.current,
        metric_type: :daily_tokens,
        value: 200
      )

      assert_equal 300, CostMetric.total_for_month(:daily_tokens)
    end
  end

  test '.avg_for_month returns correct average' do
    travel_to(Time.zone.local(2026, 6, 15)) do
      CostMetric.create!(
        date: Date.current.beginning_of_month,
        metric_type: :aurora_acu_avg,
        value: 1.0
      )
      CostMetric.create!(
        date: Date.current,
        metric_type: :aurora_acu_avg,
        value: 3.0
      )

      assert_equal 2.0, CostMetric.avg_for_month(:aurora_acu_avg)
    end
  end

  test '.avg_for_month returns 0 when no records exist' do
    assert_equal 0, CostMetric.avg_for_month(:daily_cost)
  end

  test 'daily_snapshot includes haiku_unified and parse_by_model keys' do
    today = Date.current
    [
      [ :daily_tokens_haiku,        500 ],
      [ :daily_cost_haiku,          0.04 ],
      [ :daily_tokens_parse_opus,   2000 ],
      [ :daily_cost_parse_opus,     0.03 ],
      [ :daily_tokens_parse_sonnet, 1500 ],
      [ :daily_cost_parse_sonnet,   0.005 ]
    ].each do |mt, val|
      CostMetric.create!(date: today, metric_type: mt, value: val)
    end

    snap = CostMetric.daily_snapshot(today)

    assert_equal 500,   snap[:today_tokens_haiku].to_i
    assert_in_delta 0.04, snap[:today_cost_haiku].to_f, 0.0001
    assert_equal 2000,  snap[:today_tokens_parse_opus].to_i
    assert_equal 1500,  snap[:today_tokens_parse_sonnet].to_i
    assert snap.key?(:today_cost_parse_opus),   'snapshot debe incluir today_cost_parse_opus'
    assert snap.key?(:today_cost_parse_sonnet), 'snapshot debe incluir today_cost_parse_sonnet'
  end
end
