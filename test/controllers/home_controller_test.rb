# frozen_string_literal: true

require 'test_helper'

class HomeControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TURBO_STREAM_CONTENT_TYPE = 'text/vnd.turbo-stream.html; charset=utf-8'

  setup do
    CostMetric.destroy_all
    BedrockQuery.destroy_all
  end

  test 'should get index' do
    get root_path
    assert_response :success
  end

  test 'index lists kb_documents under Base de Conocimiento with display_name' do
    KbDocument.create!(s3_key: 'uploads/2026/home_ui.pdf', display_name: 'Manual ascensor', aliases: [])

    get root_path
    assert_response :success
    assert_select 'h3', text: 'Base de Conocimiento'
    assert_select '#documents-list-container p.truncate', text: 'Manual ascensor'
  end

  test 'index renders session, recent, and knowledge base panels beside chat' do
    get root_path
    assert_response :success
    assert_select '#session-entities-list-container'
    assert_select '#technician-documents-list-container'
    assert_select '#documents-list-container'
  end

  test 'index places session and recent panels before knowledge base files card' do
    get root_path
    assert_response :success

    body = response.body
    idx_session = body.index('Archivos en la sesión')
    idx_recent = body.index('Recientes consultados')
    idx_kb = body.index('Base de Conocimiento')
    assert idx_session && idx_recent && idx_kb && idx_session < idx_recent && idx_recent < idx_kb
  end

  test 'index overview card lists session files panel above recent documents panel' do
    get root_path
    assert_response :success

    body = response.body
    idx_session = body.index('id="session-entities-list-container"')
    idx_recent = body.index('id="technician-documents-list-container"')
    assert idx_session && idx_recent && idx_session < idx_recent,
           'session entities block should render before recent technician documents block'
  end

  test 'index overview lists TechnicianDocument canonical_name numbered' do
    TechnicianDocument.delete_all
    TechnicianDocument.create!(
      identifier: "whatsapp:+56900000000",
      channel: "whatsapp",
      canonical_name: "Manual técnico overview",
      last_used_at: Time.current
    )

    get root_path
    assert_response :success
    assert_select 'h3', text: 'Recientes consultados'
    assert_select "#technician-documents-list-container p.truncate", text: 'Manual técnico overview'
    assert_match(
      %r{<span[^>]*>\s*1\s*</span>.*Manual técnico overview}m,
      response.body
    )
  end

  test 'shared MVP session shows active_entities on home without sign_in' do
    stub_shared_session_enabled_for_home_test(true) do
      ConversationSession.where(identifier: SharedSession::IDENTIFIER, channel: SharedSession::CHANNEL).delete_all
      ConversationSession.create!(
        identifier: SharedSession::IDENTIFIER,
        channel: SharedSession::CHANNEL,
        expires_at: 1.hour.from_now,
        active_entities: { "Entidad sesión compartida MVP" => { "source" => "test" } }
      )

      get root_path
      assert_response :success
      assert_select "#session-entities-list-container span.truncate", text: "Entidad sesión compartida MVP"
    end
  end

  test 'index overview uses first ConversationSession when scoped session has no entities' do
    ConversationSession.delete_all
    ConversationSession.create!(
      identifier: "whatsapp:+56900009999",
      channel: "whatsapp",
      expires_at: 1.hour.from_now,
      active_entities: { "Doc único en BD" => { "source" => "test" } }
    )

    get root_path
    assert_response :success
    assert_select "#session-entities-list-container span.truncate", text: "Doc único en BD"
  end

  test 'index overview lists active web session entity keys when signed in' do
    user = users(:one)
    ConversationSession.where(identifier: user.id.to_s, channel: "web").delete_all
    ConversationSession.create!(
      identifier: user.id.to_s,
      channel: "web",
      expires_at: 1.hour.from_now,
      active_entities: { "Esquema bomba" => { "source" => "test" } }
    )

    sign_in user, scope: :user
    get root_path
    assert_response :success
    assert_select 'h3', text: 'Archivos en la sesión'
    assert_select "#session-entities-list-container span.truncate", text: "Esquema bomba"
  end

  test 'should render index with metrics' do
    today = Date.current
    CostMetric.create!(date: today, metric_type: :daily_tokens, value: 1000)
    CostMetric.create!(date: today, metric_type: :daily_queries, value: 10)

    get root_path
    assert_response :success
    assert_select '[data-chat-usage-metrics]', minimum: 1
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
    assert_match(/target="chat-usage-metrics-container"/, response.body)
  end

  test 'metrics turbo_stream should include chat usage footer partial' do
    today = Date.current
    CostMetric.create!(date: today, metric_type: :daily_tokens, value: 5000)
    CostMetric.create!(date: today, metric_type: :daily_queries, value: 25)

    get '/home/metrics'
    assert_response :success
    assert_match(/data-chat-usage-metrics="true"/, response.body)
    assert_match(/data-metric-value="tokens"/, response.body)
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
    assert_select '#chat-usage-metrics-container [data-metric-value="tokens"]', text: /150/
  end

  def stub_shared_session_enabled_for_home_test(enabled)
    orig = SharedSession::ENABLED
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, enabled)
    yield
  ensure
    SharedSession.send(:remove_const, :ENABLED)
    SharedSession.const_set(:ENABLED, orig)
  end
end
