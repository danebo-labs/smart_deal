# frozen_string_literal: true

require "test_helper"
require "tempfile"

class PilotMetricsReportTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    BedrockQuery.delete_all
    BedrockDailyCost.delete_all
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
        assert_equal 0, cache_trace[:attributed_cost_usd]
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


  test "recent_questions is absent by default, even with quality records available" do
    travel_to @now do
      create_call(@a1, route: "rag_filtered", correlation_id: "rag:a1")

      with_usage_log do |path|
        report = PilotMetricsReport.new(date: @date, usage_log_path: path).as_json

        assert_equal "available", report.dig(:evidence_quality, :status)
        assert_not report.dig(:evidence_quality).key?(:recent_questions)
      end
    end
  end

  test "recent_questions surfaces real question text only when include_raw_questions is true" do
    travel_to @now do
      create_call(@a1, route: "rag_filtered", correlation_id: "rag:a1")
      create_call(@a2, route: "rag_filtered", correlation_id: "rag:a2")
      create_call(@b1, route: "rag_filtered", correlation_id: "rag:b1")

      with_usage_log do |path|
        report = PilotMetricsReport.new(date: @date, usage_log_path: path, include_raw_questions: true).as_json
        recent = report.dig(:evidence_quality, :recent_questions)

        assert_equal 3, recent.size
        entry = recent.find { |row| row[:correlation_id] == "rag:a1" }
        assert_equal "question from #{@a1.email}", entry[:question]
        assert_equal @a1.id, entry[:user_id]
        assert_equal true, entry[:evidence_present]
        assert_equal 1, entry[:citations_count]
        assert_equal @now.iso8601, entry[:occurred_at]
      end
    end
  end

  test "recent_questions is sorted most-recent-first and capped at RECENT_QUESTIONS_LIMIT" do
    travel_to @now do
      create_call(@a1, route: "rag_filtered", correlation_id: "rag:bulk")

      file = Tempfile.new("pilot-recent-questions")
      (PilotMetricsReport::RECENT_QUESTIONS_LIMIT + 5).times do |i|
        file.puts("[RAG_QUALITY] #{JSON.generate({
          ts: (@now - (60 - i).seconds).iso8601, account_id: accounts(:legacy).id, user_id: @a1.id,
          correlation_id: "corr-#{i}", evidence_present: true, citations_count: 0, chunk_count: 0,
          question: "question #{i}"
        })}")
      end
      file.flush

      report = PilotMetricsReport.new(date: @date, usage_log_path: file.path, include_raw_questions: true).as_json
      recent = report.dig(:evidence_quality, :recent_questions)

      assert_equal PilotMetricsReport::RECENT_QUESTIONS_LIMIT, recent.size
      assert_equal "question #{PilotMetricsReport::RECENT_QUESTIONS_LIMIT + 4}", recent.first[:question]
      assert_equal "question 5", recent.last[:question]

      file.close!
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
      assert_equal baseline.dig(:adoption_signals, :rag_llm_calls), report.dig(:adoption_signals, :rag_llm_calls)

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

  test "evidence_route_summary, traceability, cost_summary, and repeat_usage populate correctly" do
    travel_to @now do
      create_call(@a1, route: "rag_filtered", correlation_id: "corr:a1")
      create_call(@a1, route: "rag_filtered", correlation_id: "corr:a1b")
      create_call(@b1, route: "rag_filtered", correlation_id: "corr:b1")

      file = Tempfile.new("pilot-metrics-1-4")
      # evidence_route events (generation_input_tokens/generation_output_tokens are the keys
      # Rag::EvidenceSelectionTelemetry.log_route actually emits)
      [
        { event: "evidence_route", ts: @now.iso8601, correlation_id: "corr:a1", account_id: accounts(:legacy).id, user_id: @a1.id, outcome: "answered", generation_mode: "structured", retrieval_ms: 100, expansion_ms: 50, local_ms: 30, generation_ms: 200, generation_input_tokens: 50, generation_output_tokens: 25, ambiguity_detected: false },
        { event: "evidence_route", ts: @now.iso8601, correlation_id: "corr:a1b", account_id: accounts(:legacy).id, user_id: @a1.id, outcome: "abstained", generation_mode: "fallback", retrieval_ms: 80, expansion_ms: 40, local_ms: 20, generation_ms: 150, generation_input_tokens: 40, generation_output_tokens: 10, ambiguity_detected: true },
        { event: "evidence_route", ts: @now.iso8601, correlation_id: "corr:b1", account_id: accounts(:climb).id, user_id: @b1.id, outcome: "answered", generation_mode: "structured", retrieval_ms: 120, expansion_ms: 60, local_ms: 35, generation_ms: 180, generation_input_tokens: 55, generation_output_tokens: 30, ambiguity_detected: false, question_sha256: "abc123" }
      ].each { |event| file.puts("[PILOT_USAGE] #{JSON.generate(event)}") }

      # evidence_route_context events
      [
        { event: "evidence_route_context", ts: @now.iso8601, correlation_id: "corr:a1", account_id: accounts(:legacy).id, user_id: @a1.id, page: 10, section_identity: "PLACA_A", document_id: "doc_1", chunk_sha256: "chunk1" },
        { event: "evidence_route_context", ts: @now.iso8601, correlation_id: "corr:b1", account_id: accounts(:climb).id, user_id: @b1.id, page: 20, section_identity: "PLACA_B", document_id: "doc_2", chunk_sha256: "chunk2" },
        { event: "evidence_route_context", ts: @now.iso8601, correlation_id: "corr:b1", account_id: accounts(:climb).id, user_id: @b1.id, page: 21, section_identity: "PLACA_B", document_id: "doc_2", chunk_sha256: "chunk3" }
      ].each { |event| file.puts("[PILOT_USAGE] #{JSON.generate(event)}") }

      file.flush

      report = PilotMetricsReport.new(date: @date, usage_log_path: file.path).as_json

      # Check evidence_route_summary
      summary = report.dig(:technical_and_cost, :evidence_route_summary)
      assert_equal "available", summary[:status]
      assert_equal({ "answered" => 2, "abstained" => 1 }, summary[:responses_by_outcome])
      assert_equal({ "structured" => 2, "fallback" => 1 }, summary[:responses_by_generation_mode])
      assert_equal 1, summary[:ambiguity_detected_count]
      assert_in_delta(1.0 / 3, summary[:abstention_rate], 0.0001)
      assert_operator summary[:latency_stages][:retrieval_ms][:max], :>, 0
      assert_equal 145, summary[:tokens_in]
      assert_equal 65, summary[:tokens_out]

      # Check traceability
      traceability = report.dig(:technical_and_cost, :traceability)
      assert_equal 2, traceability.size
      trace_a1 = traceability.find { |t| t[:correlation_id] == "corr:a1" }
      assert_equal 1, trace_a1[:chunks_cited]
      assert_equal [ 10 ], trace_a1[:pages]
      assert_equal [ "PLACA_A" ], trace_a1[:section_identities]

      # Check cost_summary
      cost_summary = report.dig(:technical_and_cost, :cost_summary)
      assert_equal "available", cost_summary[:status]
      assert_equal 2, cost_summary[:by_user].size
      a1_cost = cost_summary[:by_user].find { |u| u[:user_id] == @a1.id }
      assert_equal 2, a1_cost[:queries]

      # Check repeat_usage
      repeat = report.dig(:repeat_usage)
      assert_equal "available", repeat[:status]
      assert_equal 1, repeat[:repeat_questions_count]
      assert_equal(
        [ { user_id: @a1.id, date: @date.iso8601, count: 2 }, { user_id: @b1.id, date: @date.iso8601, count: 1 } ].sort_by { |row| row[:user_id] },
        repeat[:queries_by_user_day].sort_by { |row| row[:user_id] }
      )
      repeated = repeat[:top_repeated_questions].first
      assert_equal @a1.id, repeated[:user_id]
      assert_nil repeated[:question_sha256]
      assert_equal 2, repeated[:count]

      file.close!
    end
  end

  test "evidence_route_summary falls back to legacy input_tokens/output_tokens for old log lines" do
    travel_to @now do
      create_call(@a1, route: "rag_filtered", correlation_id: "corr:legacy")

      file = Tempfile.new("pilot-legacy-tokens")
      file.puts("[PILOT_USAGE] #{JSON.generate({ event: "evidence_route", ts: @now.iso8601, correlation_id: "corr:legacy", account_id: accounts(:legacy).id, user_id: @a1.id, outcome: "answered", generation_mode: "structured", retrieval_ms: 90, expansion_ms: 45, local_ms: 25, generation_ms: 170, input_tokens: 60, output_tokens: 15, ambiguity_detected: false })}")
      file.flush

      report = PilotMetricsReport.new(date: @date, usage_log_path: file.path).as_json
      summary = report.dig(:technical_and_cost, :evidence_route_summary)

      assert_equal 60, summary[:tokens_in]
      assert_equal 15, summary[:tokens_out]

      file.close!
    end
  end

  test "evidence_route_summary returns logs_not_available when no evidence_route events" do
    travel_to @now do
      create_call(@a1, route: "rag_filtered", correlation_id: "rag:a1")

      file = Tempfile.new("pilot-empty-evidence")
      file.puts("[PILOT_USAGE] #{JSON.generate({ event: "photo_submitted", ts: @now.iso8601 })}")
      file.flush

      report = PilotMetricsReport.new(date: @date, usage_log_path: file.path).as_json

      assert_equal "logs_not_available", report.dig(:technical_and_cost, :evidence_route_summary, :status)
      assert_equal "logs_not_available", report.dig(:technical_and_cost, :traceability, :status)

      file.close!
    end
  end

  test "interactions returns logs_not_available when no interaction_completed events exist" do
    travel_to @now do
      report = PilotMetricsReport.new(date: @date).as_json
      assert_equal({ status: "logs_not_available" }, report[:interactions])
    end
  end

  test "interactions reconstructs seven human interactions over a synthetic three-day from:/to: range" do
    day1        = Time.zone.local(2026, 7, 20, 10, 0)
    day1_repeat = Time.zone.local(2026, 7, 20, 11, 0)
    day2_a      = Time.zone.local(2026, 7, 21, 10, 0)
    day2_photo  = Time.zone.local(2026, 7, 21, 11, 0)
    day2_abst   = Time.zone.local(2026, 7, 21, 12, 0)
    day2_failed = Time.zone.local(2026, 7, 21, 14, 0)
    day2_smoke  = Time.zone.local(2026, 7, 21, 15, 0)
    day3_edge   = Time.zone.local(2026, 7, 22, 23, 59, 50)

    travel_to day3_edge do
      q_a = Digest::SHA256.hexdigest("torque tuerca eje")
      q_b = Digest::SHA256.hexdigest("modelo motor visible")
      q_c = Digest::SHA256.hexdigest("presion sistema hidraulico")

      # Text route, one normal call and one rag_filtered -> rag_global fallback
      # (H9): two BedrockQuery rows sharing a correlation_id must collapse into
      # a single interaction, not two.
      create_call(@a1, route: "rag_filtered", correlation_id: "query:i1", created_at: day1)
      create_call(@a1, route: "rag_filtered", correlation_id: "query:i2", created_at: day1_repeat)
      create_call(@a1, route: "rag_global",   correlation_id: "query:i2", created_at: day1_repeat)
      create_call(@b1, route: "rag_filtered", correlation_id: "query:i3", created_at: day2_a)
      create_call(@a1, route: "visual_query", correlation_id: "photo:i4", created_at: day2_photo, model_id: "claude-sonnet-4-6-direct")
      create_call(@a1, route: "visual_query", correlation_id: "photo:i5", created_at: day3_edge, model_id: "claude-sonnet-4-6-direct")
      create_call(@b1, route: "rag_filtered", correlation_id: "query:i6", created_at: day2_abst)
      # Failure surfaced after Bedrock already billed the call (e.g. a
      # post-processing StandardError), so the row still exists.
      create_call(@b1, route: "rag_filtered", correlation_id: "query:i7", created_at: day2_failed)

      file = Tempfile.new("pilot-interactions")
      interaction_events = [
        { event: "interaction_completed", ts: day1.iso8601, correlation_id: "query:i1",
          user_id: @a1.id, account_id: accounts(:legacy).id, conversation_session_id: 1,
          question_sha256: q_a, outcome: "answered", route: "text" },
        { event: "interaction_completed", ts: day1_repeat.iso8601, correlation_id: "query:i2",
          user_id: @a1.id, account_id: accounts(:legacy).id, conversation_session_id: 1,
          question_sha256: q_a, outcome: "answered", route: "text" },
        { event: "interaction_completed", ts: day2_a.iso8601, correlation_id: "query:i3",
          user_id: @b1.id, account_id: accounts(:climb).id, conversation_session_id: 2,
          question_sha256: q_b, outcome: "answered", route: "text" },
        { event: "interaction_completed", ts: day2_photo.iso8601, correlation_id: "photo:i4",
          user_id: @a1.id, account_id: accounts(:legacy).id, conversation_session_id: 1,
          outcome: "answered", route: "visual_query" },
        { event: "interaction_completed", ts: day3_edge.iso8601, correlation_id: "photo:i5",
          user_id: @a1.id, account_id: accounts(:legacy).id, conversation_session_id: 1,
          outcome: "answered", route: "visual_query" },
        { event: "interaction_completed", ts: day2_abst.iso8601, correlation_id: "query:i6",
          user_id: @b1.id, account_id: accounts(:climb).id, conversation_session_id: 2,
          question_sha256: q_c, outcome: "abstained", route: "text" },
        { event: "interaction_completed", ts: day2_failed.iso8601, correlation_id: "query:i7",
          user_id: @b1.id, account_id: accounts(:climb).id, conversation_session_id: 2,
          outcome: "failed", stage: "unexpected_error", error_class: "StandardError", route: "text" },
        # Smoke ping with no pilot user — excluded by the user_ids cohort filter below,
        # never counted as an 8th human interaction.
        { event: "interaction_completed", ts: day2_smoke.iso8601, correlation_id: "query:smoke",
          account_id: accounts(:legacy).id, outcome: "answered", route: "text" }
      ]
      interaction_events.each { |event| file.puts("[PILOT_USAGE] #{JSON.generate(event)}") }

      # query:i6 (abstained) deliberately gets no evidence_route_context line —
      # abstention without chunks must not fabricate a traceability entry.
      file.puts("[PILOT_USAGE] #{JSON.generate({ event: "evidence_route_context", ts: day1.iso8601, correlation_id: "query:i1", account_id: accounts(:legacy).id, user_id: @a1.id, page: 5, section_identity: "SEC_A", document_id: "doc_1", chunk_sha256: "chunk-i1" })}")
      file.puts("[RAG_QUALITY] #{JSON.generate({ ts: day1.iso8601, account_id: accounts(:legacy).id, user_id: @a1.id, correlation_id: "query:i1", evidence_present: true, citations_count: 1, chunk_count: 2, citation_titles: [ "Manual Motor" ] })}")
      file.puts("[RAG_QUALITY] #{JSON.generate({ ts: day2_a.iso8601, account_id: accounts(:climb).id, user_id: @b1.id, correlation_id: "query:i3", evidence_present: true, citations_count: 1, chunk_count: 1, citation_titles: [ "Manual Motor" ] })}")
      file.flush

      report = PilotMetricsReport.new(
        from: Date.new(2026, 7, 20), to: Date.new(2026, 7, 22),
        usage_log_path: file.path, user_ids: [ @a1.id, @b1.id ]
      ).as_json

      interactions = report[:interactions]
      assert_equal "available", interactions[:status]
      assert_equal 7, interactions[:total], "the unattributed smoke ping must not count as an 8th interaction"
      assert_equal 8, interactions[:llm_calls_attributed], "the rag_filtered->rag_global fallback bills two calls for one interaction"
      assert_equal 8, interactions[:llm_calls_in_range]
      assert_equal 0, interactions[:zero_llm_call_interactions]
      assert_equal true, interactions.dig(:contract_checks, :single_terminal_event_per_interaction)
      assert_equal true, interactions.dig(:contract_checks, :outcomes_valid)
      assert_equal true, interactions.dig(:contract_checks, :failures_fully_traced)
      assert_equal "REQUIRES_HUMAN_REVIEW", interactions.dig(:verification, :status)
      assert_equal %w[correct_answer resolved technician_helpfulness], interactions.dig(:verification, :fields)
      assert_equal({ "answered" => 5, "abstained" => 1, "failed" => 1 }, interactions[:by_outcome])
      assert_equal 2, interactions[:active_users]
      assert_equal 0, interactions[:unattributed_count]
      assert_equal 1, interactions[:returning_users], "only a1 has activity on two distinct days (day1 and day3)"
      assert_equal interactions[:returning_users], interactions[:users_with_multiple_days]
      assert_equal 1, interactions[:repeated_questions_count], "nil question_sha256 on the two photo interactions must not be grouped as a repeat"
      repeated = interactions[:top_repeated_questions].first
      assert_equal @a1.id, repeated[:user_id]
      assert_equal q_a, repeated[:question_sha256]
      assert_equal 2, repeated[:count]
      failure = interactions[:failures].first
      assert_equal "query:i7", failure[:correlation_id]
      assert_equal "unexpected_error", failure[:stage]
      assert_equal "StandardError", failure[:error_class]

      # RAG_QUALITY and evidence_route_context stay correctly correlated and unduplicated
      # alongside the new interaction_completed events (existing, untouched sections).
      assert_equal({ "Manual Motor" => 2 }, report.dig(:evidence_quality, :referenced_documents))
      traceability = report.dig(:technical_and_cost, :traceability)
      assert_equal 1, traceability.size, "the abstained interaction (query:i6) has no chunks and must not appear here"
      assert_equal "query:i1", traceability.first[:correlation_id]
      assert_equal 1, traceability.first[:chunks_cited]

      # H10: active_days on a multi-day range must reflect distinct calendar days, not 1.
      users = report.dig(:technical_and_cost, :per_user).index_by { |row| row[:user_id] }
      assert_equal 3, users[@a1.id][:active_days]
      assert_equal 1, users[@b1.id][:active_days]

      file.close!
    end
  end

  test "interactions separates attributed calls from all range calls and counts deterministic interactions" do
    travel_to @now do
      create_call(@a1, route: "rag_filtered", correlation_id: "query:attributed")
      create_call(@b1, route: "rag_filtered", correlation_id: "query:foreign")

      file = Tempfile.new("pilot-interaction-attribution")
      [
        { event: "interaction_completed", ts: @now.iso8601, correlation_id: "query:attributed",
          account_id: @a1.account_id, user_id: @a1.id, outcome: "answered", route: "text" },
        { event: "interaction_completed", ts: @now.iso8601, correlation_id: "query:deterministic",
          account_id: @a1.account_id, user_id: @a1.id, outcome: "answered", route: "text" }
      ].each { |event| file.puts("[PILOT_USAGE] #{JSON.generate(event)}") }
      file.flush

      interactions = PilotMetricsReport.new(date: @date, usage_log_path: file.path).as_json[:interactions]

      assert_equal 1, interactions[:llm_calls_attributed]
      assert_equal 2, interactions[:llm_calls_in_range]
      assert_equal 1, interactions[:zero_llm_call_interactions]
      assert_not interactions.key?(:invariant_ok)
      assert_not interactions.key?(:llm_calls)

      file.close!
    end
  end

  test "contract checks report duplicate terminals, invalid outcomes, and untraced failures" do
    travel_to @now do
      file = Tempfile.new("pilot-contract-checks")
      [
        { event: "interaction_completed", ts: @now.iso8601, correlation_id: "query:duplicate",
          account_id: @a1.account_id, user_id: @a1.id, outcome: "answered", route: "text" },
        { event: "interaction_completed", ts: @now.iso8601, correlation_id: "query:duplicate",
          account_id: @a1.account_id, user_id: @a1.id, outcome: "answered", route: "text" },
        { event: "interaction_completed", ts: @now.iso8601, correlation_id: "query:invalid",
          account_id: @a1.account_id, user_id: @a1.id, outcome: "resolved", route: "text" },
        { event: "interaction_completed", ts: @now.iso8601, correlation_id: "query:failed",
          account_id: @a1.account_id, user_id: @a1.id, outcome: "failed", route: "text" }
      ].each { |event| file.puts("[PILOT_USAGE] #{JSON.generate(event)}") }
      file.flush

      checks = PilotMetricsReport.new(date: @date, usage_log_path: file.path)
        .as_json.dig(:interactions, :contract_checks)

      assert_equal false, checks[:single_terminal_event_per_interaction]
      assert_equal false, checks[:outcomes_valid]
      assert_equal false, checks[:failures_fully_traced]

      file.close!
    end
  end

  test "by_correlation joins terminal route context quality and Bedrock rows without raw text by default" do
    travel_to @now do
      create_call(
        @a1,
        route: "rag_filtered",
        correlation_id: "query:joined",
        token_source: "estimated"
      )
      file = Tempfile.new("pilot-by-correlation")
      file.puts("[PILOT_USAGE] #{JSON.generate({
        event: "interaction_completed", ts: @now.iso8601, correlation_id: "query:joined",
        account_id: @a1.account_id, user_id: @a1.id, conversation_session_id: 77,
        question_sha256: "question-digest", outcome: "answered", route: "text"
      })}")
      file.puts("[PILOT_USAGE] #{JSON.generate({
        event: "evidence_route", ts: @now.iso8601, correlation_id: "query:joined",
        generation_mode: "structured", retrieval_ms: 100, expansion_ms: 20,
        local_ms: 10, generation_ms: 200
      })}")
      file.puts("[PILOT_USAGE] #{JSON.generate({
        event: "evidence_route_context", ts: @now.iso8601, correlation_id: "query:joined",
        document_id: "doc-1", page: 12, section_identity: "SEC-12"
      })}")
      file.puts("[RAG_QUALITY] #{JSON.generate({
        ts: @now.iso8601, correlation_id: "query:joined", account_id: @a1.account_id,
        user_id: @a1.id, question: "raw question", answer_snippet: "raw answer",
        evidence_present: true, citations_count: 2, chunk_count: 3,
        citation_titles: [ "Manual" ]
      })}")
      file.puts("[PILOT_AUDIT] #{JSON.generate({
        ts: @now.iso8601, correlation_id: "query:joined", account_id: @a1.account_id,
        user_id: @a1.id, type: "interaction", question: "complete raw question",
        answer: "complete raw answer", answer_length: 19,
        citations: [ { number: 1, title: "Manual — p. 12", filename: "manual.pdf", page: 12 } ]
      })}")
      file.puts("[PILOT_AUDIT] #{JSON.generate({
        ts: @now.iso8601, correlation_id: "query:joined", account_id: @a1.account_id,
        user_id: @a1.id, type: "chunk", document: "Manual", page: 12,
        section_identity: "SEC-12", chunk_sha256: "chunk-sha", text: "complete chunk",
        truncated: false
      })}")
      file.flush

      private_row = PilotMetricsReport.new(date: @date, usage_log_path: file.path)
        .as_json.dig(:interactions, :by_correlation).sole
      raw_row = PilotMetricsReport.new(
        date: @date,
        usage_log_path: file.path,
        include_raw_questions: true
      ).as_json.dig(:interactions, :by_correlation).sole

      assert_equal "structured", private_row[:generation_mode]
      assert_equal({ retrieval_ms: 100, expansion_ms: 20, local_ms: 10, generation_ms: 200 }, private_row[:stages])
      assert_equal [ "doc-1" ], private_row[:documents]
      assert_equal [ 12 ], private_row[:pages]
      assert_equal [ "SEC-12" ], private_row[:section_identities]
      assert_equal true, private_row[:evidence_present]
      assert_equal 2, private_row[:citations_count]
      assert_equal 3, private_row[:retrieved_chunks]
      assert_equal "estimated", private_row[:llm_calls].sole[:token_source]
      assert_operator private_row[:attributed_cost_usd], :>, 0
      assert_nil private_row[:correct_answer]
      assert_nil private_row[:resolved]
      assert_nil private_row[:technician_helpfulness]
      assert_not private_row.key?(:question)
      assert_not private_row.key?(:answer_snippet)
      assert_not private_row.key?(:audit)
      assert_equal "raw question", raw_row[:question]
      assert_equal "raw answer", raw_row[:answer_snippet]
      assert_equal "complete raw question", raw_row.dig(:audit, :question)
      assert_equal "complete raw answer", raw_row.dig(:audit, :answer)
      assert_equal 12, raw_row.dig(:audit, :citations, 0, :page)
      assert_equal "complete chunk", raw_row.dig(:audit, :chunks, 0, :text)

      file.close!
    end
  end

  test "cost authority reports pending partial and reconciled UTC-day states without changing estimates" do
    travel_to @now do
      create_call(
        @a1,
        route: "rag_filtered",
        correlation_id: "query:estimated",
        token_source: "estimated"
      )
      create_call(
        @a1,
        route: "visual_query",
        correlation_id: "photo:provider",
        model_id: "claude-sonnet-4-6-direct",
        token_source: "provider_usage"
      )

      pending = PilotMetricsReport.new(date: @date).as_json
      pending_authority = pending.dig(:technical_and_cost, :cost_authority)
      totals = pending.dig(:technical_and_cost, :totals)

      assert_equal "pending_reconciliation", pending_authority[:status]
      assert_equal %w[2026-07-22 2026-07-23], pending_authority[:missing_utc_dates]
      assert_equal "platform_wide_all_accounts", pending_authority[:scope]
      assert_equal "partial", pending_authority[:utc_day_overlap]
      assert_operator pending_authority.dig(:anthropic_direct, :attributed_cost_usd), :>, 0
      assert_operator totals[:estimated_usd], :>, 0
      assert_operator totals[:provider_usage_usd], :>, 0
      assert_equal totals[:attributed_cost_usd], (totals[:estimated_usd] + totals[:provider_usage_usd]).round(6)

      create_daily_cost(Date.new(2026, 7, 22), cost_usd: 1.25)
      partial = PilotMetricsReport.new(date: @date).as_json.dig(:technical_and_cost, :cost_authority)
      assert_equal "partially_reconciled", partial[:status]
      assert_equal [ "2026-07-23" ], partial[:missing_utc_dates]
      assert_equal 1.25, partial[:reconciled_bedrock_usd]

      create_daily_cost(Date.new(2026, 7, 23), cost_usd: 0.75)
      reconciled = PilotMetricsReport.new(date: @date).as_json.dig(:technical_and_cost, :cost_authority)
      assert_equal "reconciled", reconciled[:status]
      assert_empty reconciled[:missing_utc_dates]
      assert_equal 2.0, reconciled[:reconciled_bedrock_usd]
    end
  end

  private

  def create_call(user, route:, correlation_id:, model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
                  created_at: @now, token_source: nil)
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
      token_source: token_source,
      created_at: created_at
    )
  end

  def create_daily_cost(date, cost_usd:)
    BedrockDailyCost.create!(
      utc_date: date,
      model_id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      invocation_count: 1,
      input_tokens: 100,
      output_tokens: 20,
      cost_usd: cost_usd,
      reconciled_at: @now
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
      file.puts("[RAG_QUALITY] #{JSON.generate({ ts: @now.iso8601, account_id: user.account_id, user_id: user.id, correlation_id: correlation_id, evidence_present: true, citations_count: 1, chunk_count: 3, citation_titles: [ 'Pilot manual' ], question: "question from #{user.email}" })}")
    end
    file.flush
    yield file.path
  ensure
    file&.close!
  end
end
