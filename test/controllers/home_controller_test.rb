# frozen_string_literal: true

require 'test_helper'

class HomeControllerTest < ActionDispatch::IntegrationTest
  TURBO_STREAM_CONTENT_TYPE = 'text/vnd.turbo-stream.html; charset=utf-8'

  setup do
    CostMetric.destroy_all
    BedrockQuery.destroy_all
  end

  test 'should get index' do
    get root_path
    assert_response :success
  end

  test 'index lists kb_documents as Archivos with display_name' do
    KbDocument.create!(s3_key: 'uploads/2026/home_ui.pdf', display_name: 'Manual ascensor', aliases: [])

    get root_path
    assert_response :success
    assert_select 'h3.section-title', text: /Archivos/
    assert_select '.document-name-primary', text: 'Manual ascensor'
  end

  test 'should render index with metrics' do
    today = Date.current
    CostMetric.create!(date: today, metric_type: :daily_tokens, value: 1000)
    CostMetric.create!(date: today, metric_type: :daily_queries, value: 10)

    get root_path
    assert_response :success
    assert_select '.metrics-group', minimum: 1
  end

  test 'should render index without metrics' do
    get root_path
    assert_response :success
  end

  test 'should render metrics as turbo_stream' do
    get '/home/metrics'
    assert_response :success
    assert_equal TURBO_STREAM_CONTENT_TYPE, response.content_type
    assert_match(/turbo-stream/, response.body)
    assert_match(/action="update"/, response.body)
    assert_match(/target="metrics-container"/, response.body)
  end

  test 'metrics turbo_stream should include metrics partial' do
    today = Date.current
    CostMetric.create!(date: today, metric_type: :daily_tokens, value: 5000)
    CostMetric.create!(date: today, metric_type: :daily_queries, value: 25)

    get '/home/metrics'
    assert_response :success
    assert_match(/metrics-group/, response.body)
  end

  test 'metrics sync from BedrockQuery when CostMetric missing for today' do
    today = Date.current
    BedrockQuery.create!(
      model_id: 'anthropic.claude-3-5-sonnet-20241022-v2:0',
      input_tokens: 100,
      output_tokens: 50,
      user_query: 'test',
      latency_ms: 100,
      created_at: today.beginning_of_day
    )

    get root_path
    assert_response :success

    assert CostMetric.exists?(date: today, metric_type: :daily_tokens),
           'CostMetric should be synced from BedrockQuery on first load'
    assert_select '.metric-value[data-metric-value="tokens"]', text: /150/
  end
end
