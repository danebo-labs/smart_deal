# frozen_string_literal: true

require 'test_helper'

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test 'should get index' do
    get dashboard_url
    assert_response :success
    assert_match(/Desglose de costos \(hoy\)/, response.body)
    assert_match(/Consultas \(Bedrock Haiku\)/, response.body)
    assert_match(/Parse batch \(Sonnet\)/, response.body)
    assert_match(/Total hoy/, response.body)
    assert_no_match(/Uso por Modelo/, response.body)
  end

  test 'should return metrics as JSON' do
    get dashboard_metrics_url, as: :json
    assert_response :success

    json = JSON.parse(@response.body)
    assert json.key?('current')
    assert json.key?('monthly')
    assert json.key?('chart')
  end

  test 'should enqueue refresh job' do
    assert_enqueued_with(job: DailyMetricsJob) do
      post dashboard_refresh_url
    end
    assert_redirected_to dashboard_path
    assert_equal I18n.t("dashboard.metrics_refreshing"), flash[:notice]
  end
end
