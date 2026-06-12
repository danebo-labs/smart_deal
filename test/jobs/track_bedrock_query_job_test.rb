# frozen_string_literal: true

require 'test_helper'

class TrackBedrockQueryJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  VALID_PARAMS = {
    model_id: 'us.anthropic.claude-haiku-4-5-20251001-v1:0',
    input_tokens: 120,
    output_tokens: 80,
    user_query: 'What is the elevator maintenance schedule?',
    latency_ms: 1500
  }.freeze

  setup do
    BedrockQuery.destroy_all
    CostMetric.destroy_all
  end

  # ── Enqueue ──────────────────────────────────────────────────────────────────

  test 'enqueues on the default queue' do
    assert_enqueued_with(job: TrackBedrockQueryJob, queue: 'default') do
      TrackBedrockQueryJob.perform_later(**VALID_PARAMS)
    end
  end

  # ── BedrockQuery creation ────────────────────────────────────────────────────

  test 'creates a BedrockQuery record with correct attributes' do
    with_turbo_broadcast_stubbed do
      assert_difference('BedrockQuery.count', 1) do
        TrackBedrockQueryJob.perform_now(**VALID_PARAMS)
      end
    end

    record = BedrockQuery.last
    assert_equal VALID_PARAMS[:model_id],      record.model_id
    assert_equal VALID_PARAMS[:input_tokens],  record.input_tokens
    assert_equal VALID_PARAMS[:output_tokens], record.output_tokens
    assert_equal VALID_PARAMS[:user_query],    record.user_query
    assert_equal VALID_PARAMS[:latency_ms],    record.latency_ms
  end

  test 'truncates user_query to 500 characters' do
    long_query = 'x' * 600

    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(**VALID_PARAMS.merge(user_query: long_query))
    end

    assert_equal 500, BedrockQuery.last.user_query.length
  end

  # ── Metrics update ───────────────────────────────────────────────────────────

  test 'calls SimpleMetricsService.update_database_metrics_only' do
    called = false
    original = SimpleMetricsService.method(:update_database_metrics_only)

    SimpleMetricsService.define_singleton_method(:update_database_metrics_only) do |**kwargs|
      called = true
      original.call(**kwargs)
    end

    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(**VALID_PARAMS)
    end

    assert called, 'update_database_metrics_only should have been called'
  ensure
    SimpleMetricsService.define_singleton_method(:update_database_metrics_only) { |**kwargs| original.call(**kwargs) }
  end

  test 'updates CostMetric records after execution' do
    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(**VALID_PARAMS)
    end

    today = Date.current
    assert CostMetric.exists?(date: today, metric_type: :daily_queries), 'daily_queries metric should exist'
    assert CostMetric.exists?(date: today, metric_type: :daily_tokens),  'daily_tokens metric should exist'
    assert CostMetric.exists?(date: today, metric_type: :daily_cost),    'daily_cost metric should exist'

    assert_equal 1, CostMetric.find_by(date: today, metric_type: :daily_queries).value.to_i
  end

  # ── Turbo broadcast ──────────────────────────────────────────────────────────

  test 'broadcasts metrics update via Turbo after completion' do
    broadcast_called = false

    with_turbo_broadcast_stubbed(->(*_args, **_kwargs) { broadcast_called = true }) do
      TrackBedrockQueryJob.perform_now(**VALID_PARAMS)
    end

    assert broadcast_called, 'Turbo broadcast should have been called'
  end

  test 'does not raise when Turbo broadcast fails' do
    with_turbo_broadcast_stubbed(->(*_args, **_kwargs) { raise 'cable error' }) do
      assert_nothing_raised do
        TrackBedrockQueryJob.perform_now(**VALID_PARAMS)
      end
    end
  end

  # ── Edge cases ───────────────────────────────────────────────────────────────

  test 'handles zero output_tokens (valid for some models)' do
    with_turbo_broadcast_stubbed do
      assert_nothing_raised do
        TrackBedrockQueryJob.perform_now(**VALID_PARAMS.merge(output_tokens: 0))
      end
    end
  end

  # ── Gate 9R I0 telemetry fields ──────────────────────────────────────────────

  test 'persists route, attempt, max_tokens, stop_reason and correlation_id' do
    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(
        **VALID_PARAMS,
        route:          'bulk_retry',
        attempt:        2,
        max_tokens:     16_000,
        stop_reason:    'end_turn',
        correlation_id: 'ingest:abcdef123456:p7'
      )
    end

    record = BedrockQuery.last
    assert_equal 'bulk_retry',             record.route
    assert_equal 2,                        record.attempt
    assert_equal 16_000,                   record.max_tokens
    assert_equal 'end_turn',               record.stop_reason
    assert_equal 'ingest:abcdef123456:p7', record.correlation_id
  end

  test 'I0 fields default to nil and blank strings are normalized to nil' do
    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(**VALID_PARAMS.merge(route: '', stop_reason: '', correlation_id: ''))
    end

    record = BedrockQuery.last
    assert_nil record.route
    assert_nil record.attempt
    assert_nil record.max_tokens
    assert_nil record.stop_reason
    assert_nil record.correlation_id
  end

  test 'correlation_id groups multiple rows of the same logical unit' do
    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(**VALID_PARAMS, route: 'batch',      attempt: 1, correlation_id: 'ingest:aa11:p3')
      TrackBedrockQueryJob.perform_now(**VALID_PARAMS, route: 'bulk_retry', attempt: 2, correlation_id: 'ingest:aa11:p3')
    end

    rows = BedrockQuery.where(correlation_id: 'ingest:aa11:p3').order(:attempt)
    assert_equal 2, rows.count
    assert_equal %w[batch bulk_retry], rows.pluck(:route)
    assert_equal [ 1, 2 ],             rows.pluck(:attempt)
  end

  # ── Deferred token counting (RAG path) ───────────────────────────────────────

  test 'counts tokens via AnthropicTokenCounter when input/output tokens are nil' do
    counted_answer = nil
    orig = AnthropicTokenCounter.method(:count_query)
    AnthropicTokenCounter.define_singleton_method(:count_query) do |prompt:, answer:, model:|
      counted_answer = answer
      { input_tokens: 4321, output_tokens: 123 }
    end

    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(
        model_id:    VALID_PARAMS[:model_id],
        user_query:  VALID_PARAMS[:user_query],
        latency_ms:  VALID_PARAMS[:latency_ms],
        prompt_text: 'full prompt with chunks',
        answer_text: 'the answer'
      )
    end

    record = BedrockQuery.last
    assert_equal 4321, record.input_tokens
    assert_equal 123,  record.output_tokens
    assert_equal 'the answer', counted_answer
  ensure
    AnthropicTokenCounter.define_singleton_method(:count_query) { |**kwargs| orig.call(**kwargs) }
  end

  test 'persists raw billed output and logs visible-output regression telemetry separately' do
    raw_answer = "Documented answer.\n<DOC_REFS>[{\"canonical_name\":\"Manual\"}]"
    log_output = StringIO.new
    capture_logger = ActiveSupport::Logger.new(log_output)
    counted_raw_answer = nil
    counted_visible_answer = nil
    original_query_counter = AnthropicTokenCounter.method(:count_query)
    original_counter = AnthropicTokenCounter.method(:count)

    AnthropicTokenCounter.define_singleton_method(:count_query) do |prompt:, answer:, model:|
      counted_raw_answer = answer
      { input_tokens: 900, output_tokens: 120 }
    end
    AnthropicTokenCounter.define_singleton_method(:count) do |text:, model:|
      counted_visible_answer = text
      45
    end

    Rails.logger.broadcast_to(capture_logger)
    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(
        model_id: VALID_PARAMS[:model_id],
        user_query: VALID_PARAMS[:user_query],
        latency_ms: VALID_PARAMS[:latency_ms],
        prompt_text: "prompt plus observed chunks",
        answer_text: raw_answer,
        visible_answer_text: "Documented answer.",
        regression_context: {
          configured_max_tokens: 3000,
          observed_chunk_basis: "bedrock_citations",
          observed_chunks: [
            {
              canonical_name: "Manual",
              doc_sha256: "abc123",
              ingestion_path: "manual_batch_v1"
            }
          ]
        }
      )
    end

    assert_equal 120, BedrockQuery.last.output_tokens
    assert_equal raw_answer, counted_raw_answer
    assert_equal "Documented answer.", counted_visible_answer
    line = log_output.string.lines.find { |message| message.include?("[RAG_REGRESSION] ") }
    assert line, "structured regression telemetry must be logged"

    payload = JSON.parse(line.split("[RAG_REGRESSION] ", 2).last)
    assert_equal 120, payload["raw_output_tokens"]
    assert_equal 45, payload["visible_output_tokens"]
    assert_equal 75, payload["hidden_output_tokens"]
    assert_equal 0.04, payload["raw_output_utilization"]
    assert_equal false, payload["possible_truncation"]
    assert_equal "manual_batch_v1", payload.dig("observed_chunks", 0, "ingestion_path")
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger) if capture_logger
    AnthropicTokenCounter.define_singleton_method(:count_query) { |**kwargs| original_query_counter.call(**kwargs) }
    AnthropicTokenCounter.define_singleton_method(:count) { |**kwargs| original_counter.call(**kwargs) }
  end

  test 'precounted tokens win over text counting (BedrockClient path stays untouched)' do
    counter_called = false
    orig = AnthropicTokenCounter.method(:count_query)
    AnthropicTokenCounter.define_singleton_method(:count_query) do |**|
      counter_called = true
      { input_tokens: 1, output_tokens: 1 }
    end

    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(**VALID_PARAMS)
    end

    assert_not counter_called, 'count_query must not run when both token counts are provided'
    record = BedrockQuery.last
    assert_equal VALID_PARAMS[:input_tokens],  record.input_tokens
    assert_equal VALID_PARAMS[:output_tokens], record.output_tokens
  ensure
    AnthropicTokenCounter.define_singleton_method(:count_query) { |**kwargs| orig.call(**kwargs) }
  end

  test 'string symbol-equivalent for model_for_counting is converted to symbol' do
    received_model = nil
    orig = AnthropicTokenCounter.method(:count_query)
    AnthropicTokenCounter.define_singleton_method(:count_query) do |prompt:, answer:, model:|
      received_model = model
      { input_tokens: 10, output_tokens: 5 }
    end

    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(
        model_id:           VALID_PARAMS[:model_id],
        user_query:         VALID_PARAMS[:user_query],
        latency_ms:         VALID_PARAMS[:latency_ms],
        prompt_text:        'p',
        answer_text:        'a',
        model_for_counting: 'haiku'
      )
    end

    assert_equal :haiku, received_model
  ensure
    AnthropicTokenCounter.define_singleton_method(:count_query) { |**kwargs| orig.call(**kwargs) }
  end

  private

  # Stubs Turbo::StreamsChannel.broadcast_update_to to avoid ActionCable
  # dependency in unit tests. Restores original in ensure block.
  #
  # @param impl [Proc, nil] replacement implementation; defaults to no-op
  def with_turbo_broadcast_stubbed(impl = nil, &block)
    original = Turbo::StreamsChannel.method(:broadcast_update_to)
    noop = impl || ->(*_args, **_kwargs) { nil }
    Turbo::StreamsChannel.define_singleton_method(:broadcast_update_to) { |*args, **kwargs| noop.call(*args, **kwargs) }
    block.call
  ensure
    Turbo::StreamsChannel.define_singleton_method(:broadcast_update_to) { |*args, **kwargs| original.call(*args, **kwargs) }
  end
end
