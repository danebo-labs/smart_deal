# frozen_string_literal: true

require 'test_helper'

class TrackBedrockQueryJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  VALID_PARAMS = {
    model_id: 'global.anthropic.claude-haiku-4-5-20251001-v1:0',
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

    SimpleMetricsService.define_singleton_method(:update_database_metrics_only) do
      called = true
      original.call
    end

    with_turbo_broadcast_stubbed do
      TrackBedrockQueryJob.perform_now(**VALID_PARAMS)
    end

    assert called, 'update_database_metrics_only should have been called'
  ensure
    SimpleMetricsService.define_singleton_method(:update_database_metrics_only) { |*args| original.call(*args) }
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

  # ── Deferred token counting (RAG path) ───────────────────────────────────────

  test 'counts tokens via AnthropicTokenCounter when input/output tokens are nil' do
    orig = AnthropicTokenCounter.method(:count_query)
    AnthropicTokenCounter.define_singleton_method(:count_query) do |prompt:, answer:, model:|
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
  ensure
    AnthropicTokenCounter.define_singleton_method(:count_query) { |**kwargs| orig.call(**kwargs) }
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
