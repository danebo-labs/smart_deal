# frozen_string_literal: true

require 'test_helper'

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test 'should get index' do
    get dashboard_url
    assert_response :success
    assert_match(/Uso y consumo/, response.body)
    assert_match(/Costo por canal LLM/, response.body)
    assert_match(/Consultas chat hoy/, response.body)
    assert_match(/Desglose de costos \(hoy\)/, response.body)
    assert_match(/Consultas \(Bedrock Haiku\)/, response.body)
    assert_match(/Total hoy/, response.body)
    assert_no_match(/Vector Store/, response.body)
    assert_no_match(/Actualizar Métricas/, response.body)
    assert_no_match(/Documentos S3/, response.body)
  end

  test 'should return metrics as JSON' do
    get dashboard_metrics_url, as: :json
    assert_response :success

    json = JSON.parse(@response.body)
    assert json.key?('current')
    assert json.key?('monthly')
    assert json.key?('chart')
    assert json['monthly'].key?('total_cost')
    assert json['monthly'].key?('total_queries')
    assert_not json['monthly'].key?('avg_acu')
    assert json['chart'].key?('labels')
    assert json['chart'].key?('datasets')
    assert_equal Date.current.end_of_month.day, json['chart']['labels'].length
  end

  test 'performance metrics use chat queries only' do
    BedrockQuery.create!(
      model_id: 'us.anthropic.claude-haiku-4-5-20251001-v1:0',
      input_tokens: 100,
      output_tokens: 50,
      latency_ms: 500,
      source: :query,
      created_at: Time.current
    )
    BedrockQuery.create!(
      model_id: 'claude-sonnet-4-6-direct',
      input_tokens: 1000,
      output_tokens: 200,
      latency_ms: 30_000,
      source: :ingestion_parse,
      created_at: Time.current
    )

    get dashboard_url
    assert_response :success
    assert_match(/Rendimiento consultas chat/, response.body)
    assert_match(/500ms/, response.body)
    assert_no_match(/30000ms/, response.body)
  end
end
