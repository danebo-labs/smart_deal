# frozen_string_literal: true

# Read-only daily pilot report. BedrockQuery is canonical for real LLM calls;
# structured logs cover zero-cost cache reuse and evidence-quality signals.
class PilotMetricsReport
  BEDROCK_COLUMNS = %i[
    source route latency_ms model_id input_tokens output_tokens
    cache_read_tokens cache_creation_tokens account_id user_id
    conversation_session_id created_at user_query correlation_id
  ].freeze
  ABSENCE_PATTERNS = {
    data_not_available: /DATA_NOT_AVAILABLE/,
    require_field_verification: /REQUIRE_FIELD_VERIFICATION/
  }.freeze
  REFORMULATION_WINDOW = 10.minutes

  def initialize(date:, usage_log_path: nil, user_ids: nil)
    @date = date.to_date
    @range = @date.in_time_zone.all_day
    @usage_log_path = usage_log_path.presence
    @user_ids = Array(user_ids).filter_map { |value| Integer(value, exception: false) }.uniq
  end

  def as_json(*)
    rows = bedrock_rows
    log_data = read_log_data
    @usage_logs_loaded = log_data[:status] == "loaded"
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
        volume_by_source: volume_by_source(rows),
        query_latency_by_route: query_latency_by_route(rows),
        model_usage: model_usage(rows),
        interaction_trace: interaction_trace(rows, log_data[:pilot], log_data[:quality]),
        per_user: users,
        per_account: accounts
      },
      adoption_signals: adoption_signals(rows, log_data[:pilot], messages, sessions),
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
    return { status: "logs_not_provided", pilot: [], quality: [] } unless @usage_log_path
    return { status: "logs_missing", pilot: [], quality: [] } unless File.file?(@usage_log_path)

    pilot = []
    quality = []
    File.foreach(@usage_log_path) do |line|
      if (payload = extract_json(line, "[PILOT_USAGE]"))
        pilot << payload if log_payload_in_range?(payload, line) && cohort_payload?(payload)
      elsif (payload = extract_json(line, "[RAG_QUALITY]"))
        quality << payload if log_payload_in_range?(payload, line) && cohort_payload?(payload)
      end
    end
    { status: "loaded", pilot: pilot, quality: quality }
  rescue StandardError => e
    Rails.logger.warn("PilotMetricsReport log read failed: #{e.class}")
    { status: "logs_unreadable", pilot: [], quality: [] }
  end

  def extract_json(line, marker)
    marker_index = line.index(marker)
    return nil unless marker_index

    JSON.parse(line[(marker_index + marker.length)..].strip).deep_symbolize_keys
  rescue JSON::ParserError
    nil
  end

  def log_payload_in_range?(payload, line)
    ts = parse_time(payload[:ts]) || parse_time(line[/\d{4}-\d{2}-\d{2}T[^\s]+/])
    ts ? @range.cover?(ts) : false
  end

  def cohort_payload?(payload)
    @user_ids.empty? || @user_ids.include?(integer_or_nil(payload[:user_id]))
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
      actual_cost: rows.sum { |row| row_cost(row) }.round(6),
      estimated_cost_avoided: cache[:estimated_cost_avoided]
    }
  end

  def volume_by_source(rows)
    rows.group_by { |row| row[:source] }.map do |source, group|
      latencies = group.filter_map { |row| row[:latency_ms] }
      {
        source: source,
        count: group.size,
        input_tokens: group.sum { |row| row[:input_tokens].to_i },
        output_tokens: group.sum { |row| row[:output_tokens].to_i },
        actual_cost: group.sum { |row| row_cost(row) }.round(6),
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
        actual_cost: group.sum { |row| row_cost(row) }.round(6)
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
        actual_cost: group.sum { |row| row_cost(row) }.round(6)
      }
    end.sort_by { |entry| entry[:route] }
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
        actual_cost: row_cost(row).round(6),
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
        actual_cost: 0,
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
        actual_cost: user_rows.sum { |row| row_cost(row) }.round(6),
        estimated_cost_avoided: cache[:estimated_cost_avoided],
        models: model_usage(user_rows),
        routes: route_usage(user_rows),
        rag_sources: source_references(quality),
        photo_insights: photo_insights(events),
        latency_p50_ms: percentile(latencies, 50),
        latency_p95_ms: percentile(latencies, 95),
        photo_delivery_latency_p50_ms: percentile(photo_latencies, 50),
        photo_delivery_latency_p95_ms: percentile(photo_latencies, 95),
        active_days: (user_rows.any? || events.any? || user_messages.any?) ? 1 : 0,
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
        actual_cost: account_rows.sum { |row| row_cost(row) }.round(6),
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
      rag_queries: rows.count { |row| query_row?(row) && !visual_row?(row) },
      photo_requests: rows.count { |row| visual_row?(row) } + cache[:hits].to_i
    }
  end

  def evidence_quality(records)
    return { status: "logs_not_available", records: nil } if records.empty?

    {
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
