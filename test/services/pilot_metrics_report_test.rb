# frozen_string_literal: true

require "test_helper"
require "tempfile"

class PilotMetricsReportTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    BedrockQuery.delete_all
    ConversationSession.delete_all
    @date = Date.new(2026, 7, 22)
    @now = Time.zone.local(2026, 7, 22, 12)
    @a1 = users(:one)
    @a2 = User.create!(email: "pilot-a2@example.com", password: "password123", account: accounts(:legacy))
    @b1 = users(:two)
  end

  test "reports three RAG calls, two visual calls, one account-scoped cache hit, and excludes yesterday" do
    travel_to @now do
      create_call(@a1, route: "rag_filtered", correlation_id: "rag:a1")
      create_call(@a1, route: "visual_query", correlation_id: "photo:a1", model_id: "claude-sonnet-4-6-direct")
      create_call(@a2, route: "rag_filtered", correlation_id: "rag:a2")
      create_call(@b1, route: "rag_filtered", correlation_id: "rag:b1")
      create_call(@b1, route: "visual_query", correlation_id: "photo:b1", model_id: "claude-sonnet-4-6-direct")
      create_sessions

      with_usage_log do |path|
        report = PilotMetricsReport.new(date: @date, usage_log_path: path).as_json
        totals = report.dig(:technical_and_cost, :totals)
        assert_equal 3, totals[:rag_llm_calls]
        assert_equal 2, totals[:visual_llm_calls]
        assert_equal 1, totals[:photo_cache_hits]
        assert_equal 1, totals[:visual_llm_calls_avoided]
        assert_operator totals[:estimated_cost_avoided], :>, 0

        users = report.dig(:technical_and_cost, :per_user).index_by { |row| row[:user_id] }
        assert_equal [ 1, 1 ], [ users[@a1.id][:queries], users[@a1.id][:visual_llm_calls] ]
        assert_equal [ 1, 1, 0 ], [ users[@a2.id][:queries], users[@a2.id][:photo_cache_hits], users[@a2.id][:visual_llm_calls] ]
        assert_equal [ 1, 1 ], [ users[@b1.id][:queries], users[@b1.id][:visual_llm_calls] ]
        assert_equal({ "Pilot manual" => 1 }, users[@a1.id][:rag_sources])
        assert_equal "global.anthropic.claude-haiku-4-5-20251001-v1:0", users[@a2.id][:models].first[:model]

        accounts = report.dig(:technical_and_cost, :per_account).index_by { |row| row[:account_id] }
        assert_equal 1, accounts[accounts(:legacy).id][:photo_cache_hits]
        assert_equal 0, accounts[accounts(:climb).id][:photo_cache_hits]
        assert_equal({ "Pilot manual" => 2 }, accounts[accounts(:legacy).id][:rag_sources])
        cache_trace = report.dig(:technical_and_cost, :interaction_trace).find { |row| row[:kind] == "photo_cache_reuse" }
        assert_equal false, cache_trace[:llm_call]
        assert_equal 0, cache_trace[:actual_cost]
        assert_equal @a2.id, cache_trace[:user_id]
        assert_equal 1, report.dig(:knowledge_gap_signals, :data_not_available_count)
        assert_equal "REQUIRES_MANUAL_SURVEY", report.dig(:commercial_outcomes, :status)
        assert_equal "available", report.dig(:evidence_quality, :status)
        assert_equal 3, report.dig(:evidence_quality, :records)
        assert_equal({ "Pilot manual" => 3 }, report.dig(:evidence_quality, :referenced_documents))
      end
    end
  end

  test "without logs cache metrics are null instead of invented" do
    travel_to @now do
      create_call(@a1, route: "rag_global", correlation_id: "rag:a1")
      report = PilotMetricsReport.new(date: @date).as_json

      assert_nil report.dig(:technical_and_cost, :totals, :photo_cache_hits)
      assert_equal "logs_not_provided", report.dig(:data_quality, :usage_log)
    end
  end


  test "internal_calls bucket counts kb_retrieve/kb_warm_ping without contaminating total_queries" do
    travel_to @now do
      create_call(@a1, route: "rag_filtered", correlation_id: "rag:a1")

      baseline = PilotMetricsReport.new(date: @date).as_json

      file = Tempfile.new("pilot-usage-internal")
      events = [
        { event: "kb_retrieve", ts: @now.iso8601, account_id: accounts(:legacy).id, correlation_id: "corr-1",
          route: "retrieve_only", latency_ms: 120, result: "ok", results_count: 5, filter_applied: true },
        { event: "kb_retrieve", ts: @now.iso8601, account_id: accounts(:legacy).id, correlation_id: "corr-2",
          route: "retrieve_only", latency_ms: 80, result: "ok", results_count: 3, filter_applied: false },
        { event: "kb_warm_ping", ts: @now.iso8601, route: "kb_warm_ping", latency_ms: 200, result: "ok" }
      ]
      events.each { |event| file.puts("[PILOT_USAGE] #{JSON.generate(event)}") }
      file.flush

      report = PilotMetricsReport.new(date: @date, usage_log_path: file.path).as_json
      internal = report.dig(:technical_and_cost, :internal_calls)

      assert_equal 2, internal.dig(:kb_retrieve, :count)
      assert_equal 100.0, internal.dig(:kb_retrieve, :avg_latency_ms)
      assert_equal 0.5, internal.dig(:kb_retrieve, :filtered_share)
      assert_equal 1, internal.dig(:kb_warm_ping, :count)
      assert_equal 200.0, internal.dig(:kb_warm_ping, :avg_latency_ms)
      assert_not internal[:kb_warm_ping].key?(:filtered_share)

      assert_equal baseline.dig(:technical_and_cost, :totals, :rag_llm_calls),
                   report.dig(:technical_and_cost, :totals, :rag_llm_calls)
      assert_equal baseline.dig(:adoption_signals, :rag_queries), report.dig(:adoption_signals, :rag_queries)

      baseline_account = baseline.dig(:technical_and_cost, :per_account).find { |row| row[:account_id] == accounts(:legacy).id }
      account = report.dig(:technical_and_cost, :per_account).find { |row| row[:account_id] == accounts(:legacy).id }
      assert_equal baseline_account[:total_queries], account[:total_queries]
    ensure
      file&.close!
    end
  end

  test "internal_calls bucket is empty when no kb_retrieve/kb_warm_ping events are logged" do
    travel_to @now do
      with_usage_log do |path|
        report = PilotMetricsReport.new(date: @date, usage_log_path: path).as_json
        internal = report.dig(:technical_and_cost, :internal_calls)

        assert_equal({ count: 0, avg_latency_ms: nil, filtered_share: nil }, internal[:kb_retrieve])
        assert_equal({ count: 0, avg_latency_ms: nil }, internal[:kb_warm_ping])
      end
    end
  end

  test "optional pilot cohort excludes same-day internal activity" do
    travel_to @now do
      create_call(@a1, route: "rag_global", correlation_id: "rag:a1")
      create_call(@b1, route: "visual_query", correlation_id: "photo:b1")

      report = PilotMetricsReport.new(date: @date, user_ids: [ @a1.id ]).as_json

      assert_equal 1, report.dig(:technical_and_cost, :totals, :rag_llm_calls)
      assert_equal 0, report.dig(:technical_and_cost, :totals, :visual_llm_calls)
      assert_equal [ @a1.id ], report.dig(:technical_and_cost, :per_user).pluck(:user_id)
    end
  end

  private

  def create_call(user, route:, correlation_id:, model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0")
    BedrockQuery.create!(
      source: "query",
      route: route,
      model_id: model_id,
      input_tokens: 100,
      output_tokens: 20,
      latency_ms: route == "visual_query" ? 900 : 300,
      user_query: "pilot #{user.email}",
      account_id: user.account_id,
      user_id: user.id,
      conversation_session_id: user.id + 1000,
      correlation_id: correlation_id,
      created_at: @now
    )
  end

  def create_sessions
    ConversationSession.create!(
      identifier: "shared-a",
      channel: "shared",
      account: accounts(:legacy),
      expires_at: 1.day.from_now,
      conversation_history: [
        { "role" => "assistant", "content" => "DATA_NOT_AVAILABLE yesterday", "ts" => 1.day.ago.iso8601, "user_id" => @a1.id },
        { "role" => "user", "content" => "A1 question", "ts" => 20.minutes.ago.iso8601, "user_id" => @a1.id, "correlation_id" => "rag:a1" },
        { "role" => "assistant", "content" => "Useful A1", "ts" => 19.minutes.ago.iso8601, "user_id" => @a1.id, "correlation_id" => "rag:a1" },
        { "role" => "user", "content" => "A2 question", "ts" => 10.minutes.ago.iso8601, "user_id" => @a2.id, "correlation_id" => "rag:a2" },
        { "role" => "assistant", "content" => "DATA_NOT_AVAILABLE", "ts" => 9.minutes.ago.iso8601, "user_id" => @a2.id, "correlation_id" => "rag:a2" }
      ]
    )
    ConversationSession.create!(
      identifier: "shared-b",
      channel: "shared",
      account: accounts(:climb),
      expires_at: 1.day.from_now,
      conversation_history: [
        { "role" => "user", "content" => "B1 question", "ts" => 5.minutes.ago.iso8601, "user_id" => @b1.id, "correlation_id" => "rag:b1" },
        { "role" => "assistant", "content" => "Useful B1", "ts" => 4.minutes.ago.iso8601, "user_id" => @b1.id, "correlation_id" => "rag:b1" }
      ]
    )
  end

  def with_usage_log
    file = Tempfile.new("pilot-usage")
    digest = Digest::SHA256.hexdigest("same-photo").first(12)
    events = [
      { event: "photo_submitted", ts: @now.iso8601, account_id: accounts(:legacy).id, user_id: @a1.id, correlation_id: "photo:a1", image_digest_prefix: digest },
      { event: "photo_cache_miss", ts: @now.iso8601, account_id: accounts(:legacy).id, user_id: @a1.id, correlation_id: "photo:a1", image_digest_prefix: digest },
      { event: "photo_completed", ts: @now.iso8601, account_id: accounts(:legacy).id, user_id: @a1.id, correlation_id: "photo:a1", cache_status: "miss", canonical_name: "Panel" },
      { event: "photo_submitted", ts: @now.iso8601, account_id: accounts(:legacy).id, user_id: @a2.id, correlation_id: "photo:a2", image_digest_prefix: digest },
      { event: "photo_cache_hit", ts: @now.iso8601, account_id: accounts(:legacy).id, user_id: @a2.id, conversation_session_id: 10, correlation_id: "photo:a2", image_digest_prefix: digest },
      { event: "visual_llm_call_avoided", ts: @now.iso8601, account_id: accounts(:legacy).id, user_id: @a2.id, correlation_id: "photo:a2", estimated_cost_avoided: 0.0012 },
      { event: "photo_completed", ts: @now.iso8601, account_id: accounts(:legacy).id, user_id: @a2.id, conversation_session_id: 10, correlation_id: "photo:a2", route: "visual_query", model: "claude-sonnet-4-6-direct", latency_ms: 5, original_latency_ms: 900, input_tokens: 100, output_tokens: 20, cost: 0, cache_status: "hit" },
      { event: "photo_submitted", ts: @now.iso8601, account_id: accounts(:climb).id, user_id: @b1.id, image_digest_prefix: digest },
      { event: "photo_cache_miss", ts: @now.iso8601, account_id: accounts(:climb).id, user_id: @b1.id, image_digest_prefix: digest },
      { event: "photo_completed", ts: @now.iso8601, account_id: accounts(:climb).id, user_id: @b1.id, cache_status: "miss", canonical_name: "Panel" },
      { event: "photo_cache_hit", ts: 1.day.ago.iso8601, account_id: accounts(:legacy).id, user_id: @a1.id }
    ]
    events.each { |event| file.puts("[PILOT_USAGE] #{JSON.generate(event)}") }
    [ [ @a1, "rag:a1" ], [ @a2, "rag:a2" ], [ @b1, "rag:b1" ] ].each do |user, correlation_id|
      file.puts("[RAG_QUALITY] #{JSON.generate({ ts: @now.iso8601, account_id: user.account_id, user_id: user.id, correlation_id: correlation_id, evidence_present: true, citations_count: 1, chunk_count: 3, citation_titles: [ 'Pilot manual' ] })}")
    end
    file.flush
    yield file.path
  ensure
    file&.close!
  end
end
