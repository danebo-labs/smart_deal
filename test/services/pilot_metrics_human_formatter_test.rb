# frozen_string_literal: true

require "test_helper"

class PilotMetricsHumanFormatterTest < ActiveSupport::TestCase
  test "renders every section of a fully populated report" do
    output = PilotMetricsHumanFormatter.new(full_report).to_s

    assert_match(/Pilot metrics — 2026-07-22 \(America\/Guayaquil\)/, output)
    assert_match(/== Totals ==/, output)
    assert_match(/RAG LLM calls: 3   Visual LLM calls: 2/, output)
    assert_match(/hit rate: 33\.3%/, output)
    assert_match(/Attributed cost: \$0\.001234/, output)

    assert_match(/== Adoption ==/, output)
    assert_match(/Active users: 3   Active accounts: 2   Sessions: 4/, output)

    assert_match(/== Interactions ==/, output)
    assert_match(/Total: 5   LLM calls attributed: 4   LLM calls in range: 5   Zero-LLM interactions: 1/, output)
    assert_match(/Verification: REQUIRES_HUMAN_REVIEW — correct_answer, resolved, technician_helpfulness/, output)
    assert_match(/By outcome: answered=4, failed=1/, output)
    assert_match(/user 12 · abc1234567… · 3x/, output)
    assert_match(/Failures: 1/, output)
    assert_match(/corr-7 · route rag_filtered · stage generation · error StandardError/, output)

    assert_match(/== Repeat usage ==/, output)
    assert_match(/Users with 2\+ active days: 1/, output)

    assert_match(/== Evidence route summary ==/, output)
    assert_match(/Abstention rate: 20\.0%/, output)
    assert_match(/retrieval_ms: p50=120ms p95=300ms max=450ms/, output)
    assert_match(/Tokens in\/out: 1200\/450/, output)

    assert_match(/== Evidence quality ==/, output)
    assert_match(/Records: 3   Evidence present: 2   Evidence missing: 1/, output)
    assert_match(/Recent questions \(raw text, opt-in\):/, output)
    assert_match(/user 12 · corr:a1 · evidence:yes · "Como cambio el rodamiento\.\.\."/, output)

    assert_match(/== Knowledge gap signals ==/, output)
    assert_match(/DATA_NOT_AVAILABLE: 1   REQUIRE_FIELD_VERIFICATION: 0   Reformulations: 2/, output)

    assert_match(/== Commercial outcomes ==\nstatus: REQUIRES_MANUAL_SURVEY/, output)

    assert_match(/== Data quality ==/, output)
    assert_match(/usage_log: loaded/, output)

    assert_match(/== Per user \(2\) ==/, output)
    assert_match(/tech1@example\.com/, output)

    assert_match(/== Per account \(1\) ==/, output)
    assert_match(/Acme Elevators/, output)
  end

  test "degraded report without usage logs renders 'not available' statuses instead of raising" do
    output = PilotMetricsHumanFormatter.new(degraded_report).to_s

    assert_match(/usage_log: logs_not_provided/, output)
    assert_match(/== Interactions ==\nstatus: logs_not_available/, output)
    assert_match(/== Evidence route summary ==\nstatus: logs_not_available/, output)
    assert_match(/== Repeat usage ==\nstatus: logs_not_available/, output)
    assert_match(/== Evidence quality ==\nstatus: logs_not_available/, output)
    assert_match(/Photo cache hits: n\/a \(hit rate: n\/a\)/, output)
    assert_no_match(/== Per user/, output)
    assert_no_match(/== Per account/, output)
  end

  test "never mutates the input report hash" do
    report = full_report
    frozen_copy = Marshal.load(Marshal.dump(report))

    PilotMetricsHumanFormatter.new(report).to_s

    assert_equal frozen_copy, report
  end

  private

  def full_report
    {
      date: "2026-07-22",
      timezone: "America/Guayaquil",
      generated_at: "2026-07-22T23:59:00-05:00",
      technical_and_cost: {
        totals: {
          rag_llm_calls: 3, visual_llm_calls: 2, photo_cache_hits: 1,
          visual_llm_calls_avoided: 1, photo_cache_hit_rate: 0.3333,
          input_tokens: 500, output_tokens: 200, attributed_cost_usd: 0.001234,
          provider_usage_usd: 0.000234, estimated_usd: 0.001,
          estimated_cost_avoided: 0.000456
        },
        evidence_route_summary: {
          status: "available",
          responses_by_outcome: { "answered" => 4, "abstained" => 1 },
          responses_by_generation_mode: { "structured" => 4, "fallback" => 1 },
          abstention_rate: 0.2,
          ambiguity_detected_count: 1,
          latency_stages: {
            retrieval_ms: { p50: 120, p95: 300, max: 450 },
            expansion_ms: { p50: 40, p95: 90, max: 100 },
            local_ms: { p50: 20, p95: 30, max: 40 },
            generation_ms: { p50: 150, p95: 200, max: 250 }
          },
          tokens_in: 1200, tokens_out: 450,
          avg_tokens_in_per_query: 240.0, avg_tokens_out_per_query: 90.0
        },
        per_user: [
          {
            user_id: 12, label: "tech1@example.com", queries: 2, photo_requests: 1,
            photo_cache_hits: 0, attributed_cost_usd: 0.0009, latency_p50_ms: 900, latency_p95_ms: 1200
          },
          {
            user_id: nil, label: "unattributed", queries: 1, photo_requests: 0,
            photo_cache_hits: nil, attributed_cost_usd: 0.0003, latency_p50_ms: nil, latency_p95_ms: nil
          }
        ],
        per_account: [
          {
            account_id: 1, account_name: "Acme Elevators", total_queries: 3,
            total_photo_requests: 2, photo_cache_hits: 1, attributed_cost_usd: 0.001234,
            latency_p50_ms: 900, latency_p95_ms: 1200
          }
        ]
      },
      interactions: {
        status: "available", total: 5, llm_calls_attributed: 4, llm_calls_in_range: 5,
        zero_llm_call_interactions: 1,
        contract_checks: {
          single_terminal_event_per_interaction: true,
          outcomes_valid: true,
          failures_fully_traced: true
        },
        verification: {
          status: "REQUIRES_HUMAN_REVIEW",
          fields: %w[correct_answer resolved technician_helpfulness]
        },
        by_outcome: { "answered" => 4, "failed" => 1 },
        active_users: 3, returning_users: 1, unattributed_count: 0,
        repeated_questions_count: 1,
        top_repeated_questions: [ { user_id: 12, question_sha256: "abc1234567890", count: 3 } ],
        failures: [ { correlation_id: "corr-7", route: "rag_filtered", stage: "generation", error_class: "StandardError" } ]
      },
      adoption_signals: {
        active_users: 3, active_accounts: 2, sessions: 4,
        user_messages: 10, assistant_messages: 9, rag_llm_calls: 3, photo_requests: 3
      },
      repeat_usage: {
        status: "available", users_with_multiple_days: 1, repeat_questions_count: 1,
        top_repeated_questions: [ { user_id: 12, question_sha256: "abc1234567890", count: 3 } ]
      },
      evidence_quality: {
        status: "available", records: 3, evidence_present: 2, evidence_missing: 1,
        citations: 4, retrieved_chunks: 6, referenced_documents: { "Manual Motor" => 2 },
        recent_questions: [
          { correlation_id: "corr:a1", account_id: 1, user_id: 12, occurred_at: "2026-07-22T23:10:00-05:00",
            question: "Como cambio el rodamiento...", evidence_present: true, citations_count: 1 }
        ]
      },
      knowledge_gap_signals: {
        data_not_available_count: 1, require_field_verification_count: 0, reformulation_count: 2
      },
      commercial_outcomes: { status: "REQUIRES_MANUAL_SURVEY" },
      data_quality: {
        usage_log: "loaded", messages_without_timestamp_excluded: 0,
        unattributed_messages: 0, limits: [ "Commercial outcomes require a field survey." ]
      }
    }
  end

  def degraded_report
    {
      date: "2026-07-23",
      timezone: "America/Guayaquil",
      generated_at: "2026-07-23T23:59:00-05:00",
      technical_and_cost: {
        totals: {
          rag_llm_calls: 1, visual_llm_calls: 0, photo_cache_hits: nil,
          visual_llm_calls_avoided: nil, photo_cache_hit_rate: nil,
          input_tokens: 50, output_tokens: 10, attributed_cost_usd: 0.0001,
          provider_usage_usd: 0, estimated_usd: 0.0001,
          estimated_cost_avoided: nil
        },
        evidence_route_summary: { status: "logs_not_available" },
        per_user: [],
        per_account: []
      },
      interactions: { status: "logs_not_available" },
      adoption_signals: { active_users: 1, active_accounts: 1, sessions: 1, user_messages: 1, assistant_messages: 1, rag_llm_calls: 1, photo_requests: 0 },
      repeat_usage: { status: "logs_not_available" },
      evidence_quality: { status: "logs_not_available", records: nil },
      knowledge_gap_signals: { data_not_available_count: 0, require_field_verification_count: 0, reformulation_count: 0 },
      commercial_outcomes: { status: "REQUIRES_MANUAL_SURVEY" },
      data_quality: { usage_log: "logs_not_provided", messages_without_timestamp_excluded: 0, unattributed_messages: 0, limits: [] }
    }
  end
end
