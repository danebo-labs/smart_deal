# frozen_string_literal: true

# Read-only daily pilot report. BedrockQuery is canonical for real LLM calls;
# structured logs cover zero-cost cache reuse and evidence-quality signals.
class PilotMetricsReport
  BEDROCK_COLUMNS = %i[
    source route latency_ms model_id input_tokens output_tokens
    cache_read_tokens cache_creation_tokens account_id user_id
    conversation_session_id created_at user_query correlation_id token_source
  ].freeze
  VALID_OUTCOMES = %w[answered abstained failed].freeze
  ABSENCE_PATTERNS = {
    data_not_available: /
      DATA_NOT_AVAILABLE |
      El\ documento\ no\ incluye\ este\ dato |
      The\ document\ does\ not\ include\ this\ information
    /ix,
    require_field_verification: /
      REQUIRES?_FIELD_VERIFICATION |
      Verificar\ en\ campo\ o\ en\ el\ esquema\ completo |
      Verify\ in\ the\ field\ or\ against\ the\ complete\ schematic
    /ix
  }.freeze
  REFORMULATION_WINDOW = 10.minutes
  RECENT_QUESTIONS_LIMIT = 50

  def initialize(date: nil, from: nil, to: nil, usage_log_path: nil, user_ids: nil,
                 roles: nil, include_raw_questions: false)
    from_date = from&.to_date
    to_date   = (to || from)&.to_date || date&.to_date
    @date     = to_date
    @range    = from_date ? from_date.in_time_zone.beginning_of_day..to_date.in_time_zone.end_of_day : @date.in_time_zone.all_day
    @usage_log_path = usage_log_path.presence
    @user_ids = Array(user_ids).filter_map { |value| Integer(value, exception: false) }.uniq
    @roles = Array(roles).filter_map { |role| role.to_s.presence }.uniq
    @include_raw_questions = include_raw_questions
  end

  def as_json(*)
    rows = bedrock_rows
    log_data = read_log_data
    @usage_logs_loaded = %w[loaded partial].include?(log_data[:status])
    messages, sessions = daily_messages_and_sessions
    users = user_reports(rows, log_data[:pilot], log_data[:quality], messages)
    accounts = account_reports(rows, log_data[:pilot], log_data[:quality], messages)
    gap_signals = knowledge_gap_signals(messages)

    {
      date: @date.to_s,
      timezone: Time.zone.name,
      generated_at: Time.current.iso8601,
      technical_and_cost: {
        totals: totals(rows, log_data[:pilot]),
        cost_authority: cost_authority(rows),
        volume_by_source: volume_by_source(rows),
        query_latency_by_route: query_latency_by_route(rows),
        model_usage: model_usage(rows),
        interaction_trace: interaction_trace(rows, log_data[:pilot], log_data[:quality]),
        internal_calls: internal_calls(log_data[:pilot]),
        evidence_route_summary: evidence_route_summary(log_data[:pilot]),
        traceability: traceability(log_data[:pilot]),
        cost_summary: cost_summary(rows, log_data[:pilot]),
        per_user: users,
        per_account: accounts
      },
      interactions: interactions(rows, log_data[:pilot], log_data[:quality], log_data[:audit]),
      adoption_signals: adoption_signals(rows, log_data[:pilot], messages, sessions),
      repeat_usage: repeat_usage(log_data[:pilot]),
      evidence_quality: evidence_quality(log_data[:quality]),
      knowledge_gap_signals: gap_signals,
      commercial_outcomes: {
        status: "REQUIRES_MANUAL_SURVEY",
        required_fields: %w[
          time_to_resolution_minutes resolved_in_first_interaction
          escalation_avoided repeat_visit_avoided technician_helpfulness_score
          confidence_before confidence_after safety_risk_identified
        ]
      },
      data_quality: {
        usage_log: log_data[:status],
        invalid_log_lines: log_data[:invalid_lines],
        log_first_ts: log_data[:first_ts],
        log_last_ts: log_data[:last_ts],
        roles_declared: log_data[:roles_declared],
        missing_roles: log_data[:missing_roles],
        legacy_cache_hit_latencies_excluded: log_data[:pilot].count do |event|
          event[:event] == "photo_completed" && event[:cache_status] == "hit" && event[:original_latency_ms].nil?
        end,
        messages_without_timestamp_excluded: @messages_without_timestamp.to_i,
        unattributed_messages: messages.count { |message| message[:user_id].nil? },
        limits: [
          "Commercial outcomes require a field survey and are never inferred from LLM activity.",
          "RAG sources come from per-interaction quality telemetry, not the session's current document snapshot.",
          "RAG token counts may be estimated where Bedrock RetrieveAndGenerate omits provider usage."
        ]
      },
      manual_batches: manual_batches
    }
  end

  private

  def bedrock_rows
    scope = BedrockQuery.where(created_at: @range)
    scope = scope.where(user_id: @user_ids) if @user_ids.any?
    scope.pluck(*BEDROCK_COLUMNS).map do |values|
      BEDROCK_COLUMNS.zip(values).to_h
    end
  end

  def daily_messages_and_sessions
    messages = []
    sessions = []
    @messages_without_timestamp = 0

    ConversationSession.where(updated_at: @range)
      .where("jsonb_array_length(conversation_history) > 0")
      .find_each do |session|
        daily = Array(session.conversation_history).filter_map do |raw|
          ts = parse_time(raw["ts"])
          unless ts
            @messages_without_timestamp += 1
            next
          end
          next unless @range.cover?(ts)
          next if @user_ids.any? && @user_ids.exclude?(integer_or_nil(raw["user_id"]))

          {
            session_id: session.id,
            account_id: session.account_id,
            user_id: integer_or_nil(raw["user_id"]),
            correlation_id: raw["correlation_id"].presence,
            role: raw["role"],
            content: raw["content"].to_s,
            ts: ts
          }
        end
        next if daily.empty?

        messages.concat(daily)
        sessions << {
          id: session.id,
          account_id: session.account_id,
          user_ids: daily.filter_map { |message| message[:user_id] }.uniq,
          active_entities: session.active_entities
        }
      end

    [ messages, sessions ]
  end

  def read_log_data
    PilotTelemetryReader.new(
      source: @usage_log_path,
      range: @range,
      user_ids: @user_ids,
      roles_declared: @roles
    ).read
  end

  def totals(rows, pilot_events)
    cache = cache_metrics(pilot_events)
    {
      rag_llm_calls: rows.count { |row| query_row?(row) && !visual_row?(row) },
      visual_llm_calls: rows.count { |row| visual_row?(row) },
      photo_cache_hits: cache[:hits],
      visual_llm_calls_avoided: cache[:avoided],
      photo_cache_hit_rate: cache[:hit_rate],
      input_tokens: rows.sum { |row| row[:input_tokens].to_i },
      output_tokens: rows.sum { |row| row[:output_tokens].to_i },
      attributed_cost_usd: rows.sum { |row| row_cost(row) }.round(6),
      provider_usage_usd: rows.select { |row| row[:token_source] == "provider_usage" }
        .sum { |row| row_cost(row) }.round(6),
      estimated_usd: rows.select { |row| row[:token_source] == "estimated" }
        .sum { |row| row_cost(row) }.round(6),
      estimated_cost_avoided: cache[:estimated_cost_avoided]
    }
  end

  def cost_authority(rows)
    utc_dates = (@range.begin.utc.to_date..@range.end.utc.to_date).to_a
    reconciled = BedrockDailyCost.for_utc_day(utc_dates)
    reconciled_dates = reconciled.distinct.pluck(:utc_date)
    missing_dates = utc_dates - reconciled_dates
    direct_by_channel = rows.group_by do |row|
      LlmUsageChannel.for(
        model_id: row[:model_id],
        source: row[:source],
        user_query: row[:user_query]
      )
    end.select { |channel, _group| channel.to_s.match?(/\Aanthropic_.+_direct\z/) }
    reconciliation_status = if missing_dates.empty?
      "reconciled"
    elsif missing_dates.size == utc_dates.size
      "pending_reconciliation"
    else
      "partially_reconciled"
    end

    {
      reconciled_bedrock_usd: reconciled.sum(:cost_usd).to_f.round(6),
      status: reconciliation_status,
      missing_utc_dates: missing_dates.map(&:iso8601),
      scope: "platform_wide_all_accounts",
      utc_day_overlap: utc_day_overlap,
      anthropic_direct: {
        scope: "cohort_attributed",
        attributed_cost_usd: direct_by_channel.values.flatten.sum { |row| row_cost(row) }.round(6),
        by_channel: direct_by_channel.transform_keys(&:to_s).transform_values do |group|
          group.sum { |row| row_cost(row) }.round(6)
        end
      }
    }
  end

  def utc_day_overlap
    first_day = @range.begin.utc.to_date
    last_day = @range.end.utc.to_date
    full_days = Time.utc(first_day.year, first_day.month, first_day.day)..
      Time.utc(last_day.year, last_day.month, last_day.day).end_of_day
    @range.begin.utc == full_days.begin && @range.end.utc == full_days.end ? "full" : "partial"
  end

  def volume_by_source(rows)
    rows.group_by { |row| row[:source] }.map do |source, group|
      latencies = group.filter_map { |row| row[:latency_ms] }
      {
        source: source,
        count: group.size,
        input_tokens: group.sum { |row| row[:input_tokens].to_i },
        output_tokens: group.sum { |row| row[:output_tokens].to_i },
        attributed_cost_usd: group.sum { |row| row_cost(row) }.round(6),
        average_latency_ms: latencies.empty? ? nil : (latencies.sum.to_f / latencies.size).round(1)
      }
    end.sort_by { |row| row[:source].to_s }
  end

  def query_latency_by_route(rows)
    rows.select { |row| query_row?(row) }
      .group_by { |row| row[:route] }
      .transform_values do |group|
        values = group.filter_map { |row| row[:latency_ms] }.sort
        { count: group.size, p50_ms: percentile(values, 50), p95_ms: percentile(values, 95), max_ms: values.max }
      end
  end

  def model_usage(rows)
    rows.group_by { |row| row[:model_id].presence || "unknown" }.map do |model, group|
      {
        model: model,
        calls: group.size,
        input_tokens: group.sum { |row| row[:input_tokens].to_i },
        output_tokens: group.sum { |row| row[:output_tokens].to_i },
        attributed_cost_usd: group.sum { |row| row_cost(row) }.round(6)
      }
    end.sort_by { |entry| entry[:model] }
  end

  def route_usage(rows)
    rows.group_by { |row| row[:route].presence || "unknown" }.map do |route, group|
      {
        route: route,
        calls: group.size,
        input_tokens: group.sum { |row| row[:input_tokens].to_i },
        output_tokens: group.sum { |row| row[:output_tokens].to_i },
        attributed_cost_usd: group.sum { |row| row_cost(row) }.round(6)
      }
    end.sort_by { |entry| entry[:route] }
  end

  # Internal Retrieve calls (Rag::AmbiguousModelResponder / Rag::DeterministicRenderer
  # / WarmBedrockKbJob) are traced via PilotUsageLog, not bedrock_queries rows — see
  # AGENTS.md "Cost First (Bedrock)". Derived from the already-parsed pilot events, so
  # this never touches query_row?/visual_row? or the totals they feed.
  def internal_calls(pilot_events)
    {
      kb_retrieve: internal_call_stats(pilot_events, "kb_retrieve", track_filter: true),
      kb_warm_ping: internal_call_stats(pilot_events, "kb_warm_ping", track_filter: false)
    }
  end

  def internal_call_stats(pilot_events, event_name, track_filter:)
    group = pilot_events.select { |event| event[:event] == event_name }
    latencies = group.filter_map { |event| event[:latency_ms] }
    stats = {
      count: group.size,
      avg_latency_ms: latencies.empty? ? nil : (latencies.sum.to_f / latencies.size).round(1)
    }
    if track_filter
      stats[:filtered_share] =
        group.empty? ? nil : (group.count { |event| event[:filter_applied] == true }.to_f / group.size).round(4)
    end
    stats
  end

  def interaction_trace(rows, pilot_events, quality_records)
    quality_by_correlation = quality_records.group_by { |record| record[:correlation_id].presence }
    real_calls = rows.map do |row|
      {
        kind: "real_llm_call",
        llm_call: true,
        account_id: integer_or_nil(row[:account_id]),
        user_id: integer_or_nil(row[:user_id]),
        conversation_session_id: integer_or_nil(row[:conversation_session_id]),
        correlation_id: row[:correlation_id],
        route: row[:route],
        model: row[:model_id],
        cache_status: visual_row?(row) ? "miss" : nil,
        input_tokens: row[:input_tokens].to_i,
        output_tokens: row[:output_tokens].to_i,
        attributed_cost_usd: row_cost(row).round(6),
        estimated_cost_avoided: 0,
        latency_ms: row[:latency_ms],
        rag_sources: source_references(quality_by_correlation[row[:correlation_id].presence]),
        occurred_at: row[:created_at]&.iso8601
      }
    end
    cache_reuse = pilot_events.select do |event|
      event[:event] == "photo_completed" && event[:cache_status] == "hit"
    end.map do |event|
      avoided = pilot_events.find do |candidate|
        candidate[:event] == "visual_llm_call_avoided" &&
          candidate[:correlation_id] == event[:correlation_id]
      end
      {
        kind: "photo_cache_reuse",
        llm_call: false,
        account_id: integer_or_nil(event[:account_id]),
        user_id: integer_or_nil(event[:user_id]),
        conversation_session_id: integer_or_nil(event[:conversation_session_id]),
        correlation_id: event[:correlation_id],
        route: event[:route],
        model: event[:model],
        cache_status: "hit",
        input_tokens: 0,
        output_tokens: 0,
        avoided_input_tokens: event[:input_tokens].to_i,
        avoided_output_tokens: event[:output_tokens].to_i,
        attributed_cost_usd: 0,
        estimated_cost_avoided: avoided&.dig(:estimated_cost_avoided).to_f.round(6),
        latency_ms: event[:original_latency_ms].present? ? integer_or_nil(event[:latency_ms]) : nil,
        original_llm_latency_ms: integer_or_nil(event[:original_latency_ms] || event[:latency_ms]),
        rag_sources: {},
        occurred_at: event[:ts]
      }
    end

    (real_calls + cache_reuse).sort_by { |entry| parse_time(entry[:occurred_at]) || Time.zone.at(0) }
  end

  def user_reports(rows, pilot_events, quality_records, messages)
    user_ids = (
      rows.filter_map { |row| integer_or_nil(row[:user_id]) } +
      pilot_events.filter_map { |event| integer_or_nil(event[:user_id]) } +
      messages.filter_map { |message| message[:user_id] }
    ).uniq
    emails = User.where(id: user_ids).pluck(:id, :email).to_h
    ids_with_unattributed = user_ids + ([ nil ] if rows.any? { |row| row[:user_id].nil? } || messages.any? { |m| m[:user_id].nil? }).to_a

    ids_with_unattributed.uniq.map do |user_id|
      user_rows = rows.select { |row| integer_or_nil(row[:user_id]) == user_id }
      events = pilot_events.select { |event| integer_or_nil(event[:user_id]) == user_id }
      quality = quality_records.select { |record| integer_or_nil(record[:user_id]) == user_id }
      user_messages = messages.select { |message| message[:user_id] == user_id }
      latencies = user_rows.filter_map { |row| row[:latency_ms] }.sort
      photo_latencies = events
        .select do |event|
          event[:event] == "photo_completed" &&
            (event[:cache_status] != "hit" || event[:original_latency_ms].present?)
        end
        .filter_map { |event| integer_or_nil(event[:latency_ms]) }.sort
      gaps = knowledge_gap_signals(user_messages)
      cache = cache_metrics(events)
      {
        user_id: user_id,
        label: user_id ? emails[user_id] : "unattributed",
        account_ids: (
          user_rows.filter_map { |row| integer_or_nil(row[:account_id]) } +
          events.filter_map { |event| integer_or_nil(event[:account_id]) } +
          user_messages.filter_map { |message| message[:account_id] }
        ).uniq,
        conversation_session_ids: (
          user_rows.filter_map { |row| integer_or_nil(row[:conversation_session_id]) } +
          events.filter_map { |event| integer_or_nil(event[:conversation_session_id]) } +
          user_messages.filter_map { |message| message[:session_id] }
        ).uniq,
        correlation_ids: (
          user_rows.filter_map { |row| row[:correlation_id].presence } +
          events.filter_map { |event| event[:correlation_id].presence }
        ).uniq,
        queries: user_rows.count { |row| query_row?(row) && !visual_row?(row) },
        photo_requests: user_rows.count { |row| visual_row?(row) } + cache[:hits].to_i,
        visual_llm_calls: user_rows.count { |row| visual_row?(row) },
        photo_cache_hits: cache[:hits],
        visual_llm_calls_avoided: cache[:avoided],
        input_tokens: user_rows.sum { |row| row[:input_tokens].to_i },
        output_tokens: user_rows.sum { |row| row[:output_tokens].to_i },
        attributed_cost_usd: user_rows.sum { |row| row_cost(row) }.round(6),
        estimated_cost_avoided: cache[:estimated_cost_avoided],
        models: model_usage(user_rows),
        routes: route_usage(user_rows),
        rag_sources: source_references(quality),
        photo_insights: photo_insights(events),
        latency_p50_ms: percentile(latencies, 50),
        latency_p95_ms: percentile(latencies, 95),
        photo_delivery_latency_p50_ms: percentile(photo_latencies, 50),
        photo_delivery_latency_p95_ms: percentile(photo_latencies, 95),
        active_days: active_days(user_rows, events, user_messages),
        errors: @usage_log_path ? events.count { |event| event[:event] == "photo_failed" } : nil,
        data_not_available: gaps[:data_not_available_count],
        require_field_verification: gaps[:require_field_verification_count],
        reformulations: gaps[:reformulation_count]
      }
    end.sort_by { |row| [ row[:user_id].nil? ? 1 : 0, row[:label].to_s ] }
  end

  def account_reports(rows, pilot_events, quality_records, messages)
    account_ids = (
      rows.filter_map { |row| integer_or_nil(row[:account_id]) } +
      pilot_events.filter_map { |event| integer_or_nil(event[:account_id]) } +
      messages.filter_map { |message| message[:account_id] }
    ).uniq
    names = Account.where(id: account_ids).pluck(:id, :display_name).to_h

    account_ids.map do |account_id|
      account_rows = rows.select { |row| integer_or_nil(row[:account_id]) == account_id }
      events = pilot_events.select { |event| integer_or_nil(event[:account_id]) == account_id }
      quality = quality_records.select { |record| integer_or_nil(record[:account_id]) == account_id }
      account_messages = messages.select { |message| message[:account_id] == account_id }
      cache = cache_metrics(events)
      latencies = account_rows.filter_map { |row| row[:latency_ms] }.sort
      {
        account_id: account_id,
        account_name: names[account_id],
        active_users: (
          account_rows.filter_map { |row| integer_or_nil(row[:user_id]) } +
          events.filter_map { |event| integer_or_nil(event[:user_id]) } +
          account_messages.filter_map { |message| message[:user_id] }
        ).uniq.size,
        correlation_ids: (
          account_rows.filter_map { |row| row[:correlation_id].presence } +
          events.filter_map { |event| event[:correlation_id].presence }
        ).uniq,
        total_queries: account_rows.count { |row| query_row?(row) && !visual_row?(row) },
        total_photo_requests: account_rows.count { |row| visual_row?(row) } + cache[:hits].to_i,
        visual_llm_calls: account_rows.count { |row| visual_row?(row) },
        photo_cache_hits: cache[:hits],
        photo_cache_misses: cache[:misses],
        photo_cache_hit_rate: cache[:hit_rate],
        visual_llm_calls_avoided: cache[:avoided],
        unique_photo_digests: cache[:unique_digests],
        input_tokens: account_rows.sum { |row| row[:input_tokens].to_i },
        output_tokens: account_rows.sum { |row| row[:output_tokens].to_i },
        attributed_cost_usd: account_rows.sum { |row| row_cost(row) }.round(6),
        estimated_cost_avoided: cache[:estimated_cost_avoided],
        models: model_usage(account_rows),
        routes: route_usage(account_rows),
        latency_p50_ms: percentile(latencies, 50),
        latency_p95_ms: percentile(latencies, 95),
        photo_error_rate: photo_error_rate(events),
        rag_sources: source_references(quality),
        photo_insights: photo_insights(events)
      }
    end.sort_by { |row| row[:account_id] }
  end

  def adoption_signals(rows, pilot_events, messages, sessions)
    cache = cache_metrics(pilot_events)
    {
      active_users: (
        rows.filter_map { |row| integer_or_nil(row[:user_id]) } +
        pilot_events.filter_map { |event| integer_or_nil(event[:user_id]) } +
        messages.filter_map { |message| message[:user_id] }
      ).uniq.size,
      active_accounts: (
        rows.filter_map { |row| integer_or_nil(row[:account_id]) } +
        pilot_events.filter_map { |event| integer_or_nil(event[:account_id]) } +
        messages.filter_map { |message| message[:account_id] }
      ).uniq.size,
      sessions: sessions.size,
      user_messages: messages.count { |message| message[:role] == "user" },
      assistant_messages: messages.count { |message| message[:role] == "assistant" },
      rag_llm_calls: rows.count { |row| query_row?(row) && !visual_row?(row) },
      photo_requests: rows.count { |row| visual_row?(row) } + cache[:hits].to_i
    }
  end

  # Single source of truth for the tracking contract (docs/rag/plan_tracking_piloto_2026-08-04.md):
  # one row per distinct correlation_id in `interaction_completed`, never one row
  # per billable Bedrock call.
  def interactions(rows, pilot_events, quality_records, audit_records)
    events = pilot_events.select { |event| event[:event] == "interaction_completed" }
    return { status: "logs_not_available" } if events.empty?

    by_correlation = events.group_by { |event| event[:correlation_id].presence }
                            .reject { |correlation_id, _group| correlation_id.nil? }
    representative = by_correlation.transform_values(&:first).values

    total = representative.size
    attributed = rows.select { |row| query_row?(row) && by_correlation.key?(row[:correlation_id]) }
    user_ids = representative.filter_map { |event| integer_or_nil(event[:user_id]) }
    returning_users = interaction_returning_users(representative)
    repeat_questions = interaction_repeat_questions(representative)
    by_outcome = representative.group_by { |event| event[:outcome] }.transform_values(&:size)
    failures = representative.select { |event| event[:outcome] == "failed" }

    {
      status: "available",
      total: total,
      by_outcome: by_outcome,
      llm_calls_attributed: attributed.size,
      llm_calls_in_range: rows.count { |row| query_row?(row) },
      zero_llm_call_interactions: by_correlation.keys.count do |correlation_id|
        attributed.none? { |row| row[:correlation_id] == correlation_id }
      end,
      contract_checks: {
        single_terminal_event_per_interaction: by_correlation.values.all? { |group| group.size == 1 },
        outcomes_valid: (by_outcome.keys - VALID_OUTCOMES).empty?,
        failures_fully_traced: failures.all? { |failure| failure[:stage].present? && failure[:error_class].present? }
      },
      verification: {
        status: "REQUIRES_HUMAN_REVIEW",
        fields: %w[correct_answer resolved technician_helpfulness]
      },
      by_correlation: interaction_rows(by_correlation, rows, pilot_events, quality_records, audit_records),
      active_users: user_ids.uniq.size,
      users_with_multiple_days: returning_users,
      returning_users: returning_users,
      repeated_questions_count: repeat_questions.size,
      top_repeated_questions: repeat_questions.sort_by { |_key, count| -count }.first(10).map do |(user_id, question_sha256), count|
        { user_id: user_id, question_sha256: question_sha256, count: count }
      end,
      failures: failures.map do |event|
        {
          correlation_id: event[:correlation_id],
          route: event[:route],
          stage: event[:stage],
          error_class: event[:error_class]
        }
      end,
      unattributed_count: representative.count { |event| integer_or_nil(event[:user_id]).nil? }
    }
  end

  def interaction_rows(by_correlation, rows, pilot_events, quality_records, audit_records)
    routes = pilot_events.select { |event| event[:event] == "evidence_route" }
      .group_by { |event| event[:correlation_id].presence }
    contexts = pilot_events.select { |event| event[:event] == "evidence_route_context" }
      .group_by { |event| event[:correlation_id].presence }
    quality = quality_records.group_by { |record| record[:correlation_id].presence }
    audits = audit_records.group_by { |record| record[:correlation_id].presence }
    calls = rows.select { |row| query_row?(row) }
      .group_by { |row| row[:correlation_id].presence }

    by_correlation.map do |correlation_id, terminal_events|
      terminal = terminal_events.first
      route = Array(routes[correlation_id]).first || {}
      context = Array(contexts[correlation_id])
      quality_record = Array(quality[correlation_id]).first || {}
      audit = Array(audits[correlation_id])
      call_rows = Array(calls[correlation_id])
      result = {
        correlation_id: correlation_id,
        occurred_at: terminal[:ts],
        account_id: integer_or_nil(terminal[:account_id]),
        user_id: integer_or_nil(terminal[:user_id]),
        conversation_session_id: integer_or_nil(terminal[:conversation_session_id]),
        outcome: terminal[:outcome],
        route: terminal[:route],
        stage: terminal[:stage],
        error_class: terminal[:error_class],
        question_sha256: terminal[:question_sha256],
        generation_mode: route[:generation_mode],
        stages: {
          retrieval_ms: route[:retrieval_ms],
          expansion_ms: route[:expansion_ms],
          local_ms: route[:local_ms],
          generation_ms: route[:generation_ms]
        },
        documents: context.filter_map { |event| event[:document_id].presence }.uniq,
        pages: context.filter_map { |event| event[:page].presence }.uniq,
        section_identities: context.filter_map { |event| event[:section_identity].presence }.uniq,
        evidence_present: quality_record[:evidence_present],
        citations_count: quality_record[:citations_count].to_i,
        citation_titles: Array(quality_record[:citation_titles]).compact_blank,
        retrieved_chunks: quality_record[:chunk_count].to_i,
        models: call_rows.filter_map { |row| row[:model_id].presence }.uniq,
        input_tokens: call_rows.sum { |row| row[:input_tokens].to_i },
        output_tokens: call_rows.sum { |row| row[:output_tokens].to_i },
        attributed_cost_usd: call_rows.sum { |row| row_cost(row) }.round(6),
        llm_calls: call_rows.map do |row|
          {
            model: row[:model_id],
            input_tokens: row[:input_tokens].to_i,
            output_tokens: row[:output_tokens].to_i,
            token_source: row[:token_source],
            attributed_cost_usd: row_cost(row).round(6)
          }
        end,
        correct_answer: nil,
        resolved: nil,
        technician_helpfulness: nil
      }
      if @include_raw_questions
        result[:question] = quality_record[:question]
        result[:answer_snippet] = quality_record[:answer_snippet]
        interaction_audit = audit.find { |record| record[:type] == "interaction" }
        if interaction_audit
          result[:audit] = {
            question: interaction_audit[:question],
            answer: interaction_audit[:answer],
            answer_length: interaction_audit[:answer_length].to_i,
            citations: Array(interaction_audit[:citations]),
            chunks: audit.select { |record| record[:type] == "chunk" }.map do |record|
              record.slice(:document, :page, :section_identity, :chunk_sha256, :text, :truncated)
            end
          }
        end
      end
      result
    end.sort_by { |row| row[:correlation_id] }
  end

  def interaction_returning_users(representative_events)
    by_user_day = representative_events.filter_map do |event|
      user_id = integer_or_nil(event[:user_id])
      ts = parse_time(event[:ts])
      [ user_id, ts.to_date ] if user_id && ts
    end.uniq
    by_user_day.group_by { |(user_id, _day)| user_id }.count { |_user_id, days| days.size >= 2 }
  end

  # Nil question_sha256 (photo/visual_query interactions carry none — Fase 1
  # note #3) must never collide with each other under the same key.
  def interaction_repeat_questions(representative_events)
    representative_events
      .select { |event| event[:question_sha256].presence }
      .group_by { |event| [ integer_or_nil(event[:user_id]), event[:question_sha256] ] }
      .transform_values(&:size)
      .select { |_key, count| count > 1 }
  end

  def evidence_quality(records)
    return { status: "logs_not_available", records: nil } if records.empty?

    result = {
      status: "available",
      records: records.size,
      evidence_present: records.count { |record| record[:evidence_present] == true },
      evidence_missing: records.count { |record| record[:evidence_present] == false },
      citations: records.sum { |record| record[:citations_count].to_i },
      source_references: records.sum { |record| source_references([ record ]).values.sum },
      referenced_documents: source_references(records),
      retrieved_chunks: records.sum { |record| record[:chunk_count].to_i },
      by_account: records.group_by { |record| integer_or_nil(record[:account_id]) }.map do |account_id, group|
        {
          account_id: account_id,
          records: group.size,
          evidence_present: group.count { |record| record[:evidence_present] == true },
          referenced_documents: source_references(group)
        }
      end,
      by_user: records.group_by { |record| integer_or_nil(record[:user_id]) }.map do |user_id, group|
        {
          user_id: user_id,
          records: group.size,
          evidence_present: group.count { |record| record[:evidence_present] == true },
          referenced_documents: source_references(group)
        }
      end
    }
    result[:recent_questions] = recent_questions(records) if @include_raw_questions
    result
  end

  # Opt-in only (`include_raw_questions:`). [RAG_QUALITY] already carries real
  # question text (BedrockRagService#log_quality_signal truncates to 300 chars)
  # unlike interaction_completed, which hashes the question before it is ever
  # logged (RagController#ask). Text-route queries only — photo/visual queries
  # never emit a [RAG_QUALITY] line.
  def recent_questions(records)
    records
      .sort_by { |record| parse_time(record[:ts]) || Time.zone.at(0) }
      .last(RECENT_QUESTIONS_LIMIT)
      .reverse
      .map do |record|
        {
          correlation_id: record[:correlation_id],
          account_id: integer_or_nil(record[:account_id]),
          user_id: integer_or_nil(record[:user_id]),
          occurred_at: record[:ts],
          question: record[:question],
          evidence_present: record[:evidence_present],
          citations_count: record[:citations_count].to_i
        }
      end
  end

  def knowledge_gap_signals(messages)
    assistants = messages.select { |message| message[:role] == "assistant" }
    absence_questions = []
    assistants.each do |assistant|
      marker = ABSENCE_PATTERNS.find { |_key, pattern| assistant[:content].match?(pattern) }&.first
      next unless marker

      previous = messages.select do |message|
        message[:session_id] == assistant[:session_id] && message[:role] == "user" && message[:ts] <= assistant[:ts]
      end.max_by { |message| message[:ts] }
      absence_questions << {
        account_id: assistant[:account_id],
        user_id: assistant[:user_id] || previous&.dig(:user_id),
        session_id: assistant[:session_id],
        correlation_id: assistant[:correlation_id] || previous&.dig(:correlation_id),
        marker: marker.to_s.upcase,
        question: previous&.dig(:content),
        answered_at: assistant[:ts]&.iso8601
      }
    end

    {
      data_not_available_count: assistants.count { |message| message[:content].match?(ABSENCE_PATTERNS[:data_not_available]) },
      require_field_verification_count: assistants.count { |message| message[:content].match?(ABSENCE_PATTERNS[:require_field_verification]) },
      reformulation_count: reformulation_count(messages),
      absence_questions: absence_questions.first(50)
    }
  end

  def reformulation_count(messages)
    messages.select { |message| message[:role] == "user" }
      .group_by { |message| [ message[:session_id], message[:user_id] ] }
      .sum do |_key, group|
        group.sort_by { |message| message[:ts] }.each_cons(2).count do |first, second|
          next false unless (second[:ts] - first[:ts]) < REFORMULATION_WINDOW

          useful = messages.any? do |candidate|
            candidate[:session_id] == first[:session_id] &&
              candidate[:role] == "assistant" &&
              candidate[:ts] > first[:ts] && candidate[:ts] < second[:ts] &&
              ABSENCE_PATTERNS.values.none? { |pattern| candidate[:content].match?(pattern) }
          end
          !useful
        end
      end
  end

  def evidence_route_summary(pilot_events)
    routes = pilot_events.select { |event| event[:event] == "evidence_route" }
    return { status: "logs_not_available" } if routes.empty?

    outcomes = routes.group_by { |route| route[:outcome] }.transform_values(&:size)
    generation_modes = routes.group_by { |route| route[:generation_mode] }.transform_values(&:size)
    latencies = routes.filter_map { |route| route[:retrieval_ms].to_i }
    expansion_ms = routes.filter_map { |route| route[:expansion_ms].to_i }
    local_ms = routes.filter_map { |route| route[:local_ms].to_i }
    generation_ms = routes.filter_map { |route| route[:generation_ms].to_i }
    tokens_in = routes.sum { |r| route_token_count(r, :generation_input_tokens, :input_tokens) }
    tokens_out = routes.sum { |r| route_token_count(r, :generation_output_tokens, :output_tokens) }

    {
      status: "available",
      responses_by_outcome: outcomes,
      responses_by_generation_mode: generation_modes,
      abstention_rate: routes.count { |r| r[:outcome] == "abstained" }.to_f / [ routes.size, 1 ].max,
      ambiguity_detected_count: routes.count { |r| r[:ambiguity_detected] == true },
      latency_stages: {
        retrieval_ms: { p50: percentile(latencies.sort, 50), p95: percentile(latencies.sort, 95), max: latencies.max },
        expansion_ms: { p50: percentile(expansion_ms.sort, 50), p95: percentile(expansion_ms.sort, 95), max: expansion_ms.max },
        local_ms: { p50: percentile(local_ms.sort, 50), p95: percentile(local_ms.sort, 95), max: local_ms.max },
        generation_ms: { p50: percentile(generation_ms.sort, 50), p95: percentile(generation_ms.sort, 95), max: generation_ms.max }
      },
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      avg_tokens_in_per_query: (tokens_in.to_f / routes.size).round(1),
      avg_tokens_out_per_query: (tokens_out.to_f / routes.size).round(1)
    }
  end

  # EvidenceSelectionTelemetry.log_route emits generation_input_tokens/generation_output_tokens;
  # input_tokens/output_tokens is a fallback for evidence_route log lines written before that
  # emitter existed, never a key the current emitter uses.
  def route_token_count(route, key, legacy_key)
    (route[key] || route[legacy_key]).to_i
  end

  def traceability(pilot_events)
    contexts = pilot_events.select { |event| event[:event] == "evidence_route_context" }
    return { status: "logs_not_available" } if contexts.empty?

    by_correlation = contexts.group_by { |event| event[:correlation_id].presence }
    by_correlation.reject { |k, _v| k.nil? }.map do |correlation_id, chunks|
      pages = chunks.filter_map { |chunk| chunk[:page].presence }.uniq
      section_identities = chunks.filter_map { |chunk| chunk[:section_identity].presence }.uniq
      {
        correlation_id: correlation_id,
        chunks_cited: chunks.size,
        pages: pages,
        section_identities: section_identities,
        documents: chunks.filter_map { |chunk| chunk[:document_id].presence }.uniq
      }
    end.sort_by { |entry| entry[:correlation_id] }
  end

  def cost_summary(rows, pilot_events)
    routes = pilot_events.select { |event| event[:event] == "evidence_route" }
    return { status: "logs_not_available" } if routes.empty? || rows.empty?

    cost_by_query = routes.map do |route|
      cost_row = rows.find { |r| r[:correlation_id] == route[:correlation_id] }
      cost = cost_row ? row_cost(cost_row) : 0
      {
        correlation_id: route[:correlation_id],
        user_id: integer_or_nil(route[:user_id]),
        cost_usd: cost.round(6)
      }
    end

    by_user = cost_by_query.group_by { |entry| entry[:user_id] }
    {
      status: "available",
      total_usd: cost_by_query.sum { |entry| entry[:cost_usd] }.round(6),
      avg_cost_per_query_usd: (cost_by_query.sum { |entry| entry[:cost_usd] }.to_f / cost_by_query.size).round(6),
      by_user: by_user.map do |user_id, entries|
        {
          user_id: user_id,
          queries: entries.size,
          total_cost_usd: entries.sum { |e| e[:cost_usd] }.round(6),
          avg_cost_per_query_usd: (entries.sum { |e| e[:cost_usd] }.to_f / entries.size).round(6)
        }
      end.sort_by { |entry| -entry[:total_cost_usd] }
    }
  end

  def repeat_usage(pilot_events)
    routes = pilot_events.select { |event| event[:event] == "evidence_route" }
    return { status: "logs_not_available" } if routes.empty?

    by_user_day = routes.group_by do |route|
      user_id = integer_or_nil(route[:user_id])
      ts = parse_time(route[:ts])
      day = ts ? ts.to_date : "unknown"
      [ user_id, day ]
    end

    queries_by_user_day = by_user_day.map do |(user_id, day), group|
      { user_id: user_id, date: day == "unknown" ? "unknown" : day.iso8601, count: group.size }
    end.first(50)
    users_by_days = by_user_day.keys.group_by { |k| k[0] }.transform_values { |keys| keys.map { |k| k[1] }.uniq }

    repeat_questions = routes.group_by do |route|
      [ integer_or_nil(route[:user_id]), route[:question_sha256].presence ]
    end.transform_values(&:size).select { |_key, count| count > 1 }

    top_repeated_questions = repeat_questions.sort_by { |_key, count| -count }.first(10).map do |(user_id, question_sha256), count|
      { user_id: user_id, question_sha256: question_sha256, count: count }
    end

    {
      status: "available",
      queries_by_user_day: queries_by_user_day,
      users_with_multiple_days: users_by_days.count { |_user_id, days| days.size >= 2 },
      repeat_questions_count: repeat_questions.size,
      top_repeated_questions: top_repeated_questions
    }
  end

  def cache_metrics(events)
    return {
      hits: nil, misses: nil, avoided: nil, hit_rate: nil,
      estimated_cost_avoided: nil, unique_digests: nil
    } unless @usage_logs_loaded

    hits = events.count { |event| event[:event] == "photo_cache_hit" }
    misses = events.count { |event| event[:event] == "photo_cache_miss" }
    denominator = hits + misses
    {
      hits: hits,
      misses: misses,
      avoided: events.count { |event| event[:event] == "visual_llm_call_avoided" },
      hit_rate: denominator.zero? ? 0.0 : (hits.to_f / denominator).round(4),
      estimated_cost_avoided: events
        .select { |event| event[:event] == "visual_llm_call_avoided" }
        .sum { |event| event[:estimated_cost_avoided].to_f }.round(6),
      unique_digests: events
        .select { |event| event[:event] == "photo_submitted" }
        .filter_map { |event| event[:image_digest_prefix].presence }.uniq.size
    }
  end

  def photo_error_rate(events)
    return nil unless @usage_logs_loaded

    submitted = events.count { |event| event[:event] == "photo_submitted" }
    return 0.0 if submitted.zero?

    (events.count { |event| event[:event] == "photo_failed" }.to_f / submitted).round(4)
  end

  def photo_insights(events)
    completed = events.select { |event| event[:event] == "photo_completed" }
    {
      components: completed.filter_map { |event| event[:canonical_name].presence }.tally,
      manufacturers: completed.filter_map { |event| event[:manufacturer].presence }.tally,
      visible_models: completed.filter_map { |event| event[:model_visible].presence }.tally,
      conditions: completed.filter_map { |event| event[:condition].presence }.tally,
      unknown_count: completed.count do |event|
        [ event[:canonical_name], event[:manufacturer], event[:model_visible], event[:condition] ].any? do |value|
          value.to_s.casecmp?("UNKNOWN")
        end
      end
    }
  end

  def source_references(records)
    Array(records).flat_map do |record|
      docs = Array(record[:doc_refs]).filter_map do |doc|
        value = doc.to_h.deep_symbolize_keys
        value[:canonical_name].presence
      end
      docs.presence || Array(record[:citation_titles]).compact_blank
    end.tally.sort_by { |name, count| [ -count, name ] }.first(20).to_h
  end

  def manual_batches
    WebManualBatch.order(:id).pluck(:id, :account_id, :status, :chunks_count, :filename).map do |values|
      %i[id account_id status chunks_count filename].zip(values).to_h
    end
  end

  def query_row?(row)
    row[:source] == "query"
  end

  def visual_row?(row)
    query_row?(row) && row[:route] == "visual_query"
  end

  def row_cost(row)
    BedrockQuery.new(
      model_id: row[:model_id],
      input_tokens: row[:input_tokens],
      output_tokens: row[:output_tokens],
      cache_read_tokens: row[:cache_read_tokens],
      cache_creation_tokens: row[:cache_creation_tokens]
    ).cost
  end

  # H10: fixed at 1 in a single-day report; a multi-day @range must count
  # distinct calendar days with any activity instead.
  def active_days(user_rows, events, user_messages)
    (
      user_rows.filter_map { |row| row[:created_at]&.to_date } +
      events.filter_map { |event| parse_time(event[:ts])&.to_date } +
      user_messages.filter_map { |message| message[:ts]&.to_date }
    ).uniq.size
  end

  def percentile(sorted_values, pct)
    return nil if sorted_values.empty?

    sorted_values[((pct / 100.0) * (sorted_values.size - 1)).round]
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError, TypeError
    nil
  end

  def integer_or_nil(value)
    Integer(value, exception: false)
  end
end
