# frozen_string_literal: true

require "test_helper"

class TrackWhatsappCacheHitJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  setup do
    WhatsappCacheHit.destroy_all
    BedrockQuery.destroy_all
    CostMetric.destroy_all
  end

  def with_turbo_stubbed
    orig = Turbo::StreamsChannel.method(:broadcast_update_to)
    Turbo::StreamsChannel.define_singleton_method(:broadcast_update_to) { |*a, **k| nil }
    yield
  ensure
    Turbo::StreamsChannel.define_singleton_method(:broadcast_update_to) { |*a, **k| orig.call(*a, **k) }
  end

  test "creates a WhatsappCacheHit record with recipient and route" do
    with_turbo_stubbed do
      assert_difference "WhatsappCacheHit.count", 1 do
        TrackWhatsappCacheHitJob.perform_now(recipient: "whatsapp:+56912345678", route: "section_hit")
      end
    end

    hit = WhatsappCacheHit.last
    assert_equal "whatsapp:+56912345678", hit.recipient
    assert_equal "section_hit",           hit.route
  end

  test "tokens_saved_estimate defaults to 0 when no prior queries exist" do
    with_turbo_stubbed do
      TrackWhatsappCacheHitJob.perform_now(recipient: "whatsapp:+1", route: "section_hit")
    end

    assert_equal 0, WhatsappCacheHit.last.tokens_saved_estimate
  end

  test "tokens_saved_estimate reflects avg of last 50 query records" do
    3.times do |i|
      BedrockQuery.create!(
        model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
        input_tokens: 1000, output_tokens: 200,
        user_query: "q#{i}", latency_ms: 100, source: :query
      )
    end

    with_turbo_stubbed do
      TrackWhatsappCacheHitJob.perform_now(recipient: "whatsapp:+2", route: "show_doc_list")
    end

    assert_equal 1200, WhatsappCacheHit.last.tokens_saved_estimate
  end

  test "updates CostMetric daily_cache_hits" do
    with_turbo_stubbed do
      TrackWhatsappCacheHitJob.perform_now(recipient: "whatsapp:+3", route: "no_context_help")
    end

    assert CostMetric.exists?(date: Date.current, metric_type: :daily_cache_hits)
    assert_equal 1, CostMetric.find_by(date: Date.current, metric_type: :daily_cache_hits).value.to_i
  end

  test "does not raise on invalid route (rescued internally)" do
    with_turbo_stubbed do
      assert_nothing_raised do
        TrackWhatsappCacheHitJob.perform_now(recipient: "whatsapp:+4", route: "invalid_route")
      end
    end
  end
end
