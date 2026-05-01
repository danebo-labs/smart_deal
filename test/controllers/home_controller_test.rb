# frozen_string_literal: true

require 'test_helper'

class HomeControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TURBO_STREAM_CONTENT_TYPE = 'text/vnd.turbo-stream.html; charset=utf-8'

  setup do
    CostMetric.destroy_all
    BedrockQuery.destroy_all
    KbDocument.destroy_all
    sign_in users(:one), scope: :user
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
    assert_select '#kb-docs-desktop-items button[data-doc-name="Manual ascensor"]'
    assert_select '#kb-docs-mobile-items  button[data-doc-name="Manual ascensor"]'
  end

  test 'documents action returns turbo_stream updates for both desktop and mobile items' do
    KbDocument.create!(s3_key: 'uploads/2026/a.pdf', display_name: 'A', aliases: [])

    get '/home/documents'
    assert_response :success
    assert_equal TURBO_STREAM_CONTENT_TYPE, response.content_type
    assert_match(/target="kb-docs-desktop-items"/, response.body)
    assert_match(/target="kb-docs-mobile-items"/,  response.body)
  end

  test 'index shows sentinel when more than PAGE_SIZE docs exist' do
    21.times { |i| KbDocument.create!(s3_key: "uploads/2026/d#{i}.pdf", display_name: "Doc #{i}", aliases: []) }
    get root_path
    assert_select '#kb-docs-desktop-sentinel'
    assert_select '#kb-docs-mobile-sentinel'
  end

  test 'index hides sentinel when at most PAGE_SIZE docs exist' do
    20.times { |i| KbDocument.create!(s3_key: "uploads/2026/d#{i}.pdf", display_name: "Doc #{i}", aliases: []) }
    get root_path
    assert_select '#kb-docs-desktop-sentinel', count: 0
    assert_select '#kb-docs-mobile-sentinel',  count: 0
  end

  test 'documents_page appends next 20 rows and removes sentinel when no more pages' do
    25.times { |i| KbDocument.create!(s3_key: "uploads/2026/p#{i}.pdf", display_name: "Page #{i}", aliases: []) }

    get '/home/documents_page', params: { page: 1 }
    assert_response :success
    assert_match(/action="append" target="kb-docs-desktop-items"/, response.body)
    assert_match(/action="append" target="kb-docs-mobile-items"/,  response.body)
    # 25 total, page 0 has 20, page 1 has 5 → no more pages, sentinels removed
    assert_match(/action="remove" target="kb-docs-desktop-sentinel"/, response.body)
    assert_match(/action="remove" target="kb-docs-mobile-sentinel"/,  response.body)
  end

  test 'documents_page replaces sentinel when more pages remain' do
    45.times { |i| KbDocument.create!(s3_key: "uploads/2026/p#{i}.pdf", display_name: "P#{i}", aliases: []) }

    get '/home/documents_page', params: { page: 1 }
    assert_match(/action="replace" target="kb-docs-desktop-sentinel"/, response.body)
    assert_match(/data-docs-scroll-page-value="2"/, response.body)
  end

  test 'kb_docs_card renders thumbnail img only for image extensions with thumbnail row' do
    pdf = KbDocument.create!(s3_key: 'uploads/2026/foo.pdf', display_name: 'PDF', aliases: [])
    jpg = KbDocument.create!(s3_key: 'uploads/2026/foo.jpg', display_name: 'JPG', aliases: [])
    jpg.create_thumbnail!(data: "fake", content_type: "image/jpeg", byte_size: 4)

    get root_path
    # One img per layout (desktop + mobile) = 2 total
    assert_select %(button[data-doc-name="JPG"] img), 2
    assert_select %(button[data-doc-name="PDF"] img), 0
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
    CostMetric.create!(date: today, metric_type: :daily_tokens,       value: 5000)
    CostMetric.create!(date: today, metric_type: :daily_tokens_query,  value: 3000)
    CostMetric.create!(date: today, metric_type: :daily_tokens_parse,  value: 1000)
    CostMetric.create!(date: today, metric_type: :daily_tokens_embed,  value: 1000)
    CostMetric.create!(date: today, metric_type: :daily_queries,       value: 25)

    get '/home/metrics'
    assert_response :success
    assert_match(/data-chat-usage-metrics="true"/, response.body)
    assert_match(/Consultas \(Haiku\)/,            response.body)
    assert_match(/Parsing \(Opus\)/,               response.body)
    assert_match(/Embeddings \(Nova\)/,            response.body)
    assert_match(/Total hoy/,                      response.body)
    assert_match(/variar ±10%/,                    response.body)
  end

  test 'metrics footer shows cache savings line when cache_hits present' do
    today = Date.current
    CostMetric.create!(date: today, metric_type: :daily_tokens,      value: 0)
    CostMetric.create!(date: today, metric_type: :daily_cache_hits,  value: 5)
    CostMetric.create!(date: today, metric_type: :daily_tokens_saved, value: 6000)

    get '/home/metrics'
    assert_response :success
    assert_match(/Cache WA.*5 hits/m, response.body)
    assert_match(/6,000|6000/,        response.body)
  end

  test 'metrics footer hides cache savings line when no cache_hits' do
    today = Date.current
    CostMetric.create!(date: today, metric_type: :daily_tokens,     value: 0)
    CostMetric.create!(date: today, metric_type: :daily_cache_hits, value: 0)

    get '/home/metrics'
    assert_response :success
    assert_no_match(/Cache WA.*hits/, response.body)
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
    assert_select '#chat-usage-metrics-container [data-chat-usage-metrics]'
  end
end
