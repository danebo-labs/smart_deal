# frozen_string_literal: true

# Pilot daily metrics export — DB-only, read-only, single JSON object to stdout.
# No Bedrock/API calls; safe to run against production during the pilot.
#
# Usage:
#   bin/rails runner script/pilot_metrics_export.rb              # today (Time.zone day)
#   bin/rails runner script/pilot_metrics_export.rb 2026-07-09   # specific date (Time.zone day)
#
# Run once/day during the pilot via:
#   kamal app exec --reuse -r web "bin/rails runner script/pilot_metrics_export.rb"
#
# Complementary log-based signal (NOT computed here — Docker logs rotate;
# run this extraction the same day as the export, before logs roll over):
#   kamal app logs --lines 5000 | grep 'RAG_QUALITY' | sed 's/.*\[RAG_QUALITY\] //' | \
#     jq -s '{records: length, evidence_present: map(select(.evidence_present)) | length, evidence_missing_questions: map(select(.evidence_present == false) | {question, evidence_mode, latency_ms}), by_mode: group_by(.evidence_mode) | map({mode: .[0].evidence_mode, n: length})}'

abort("Run with: bin/rails runner script/pilot_metrics_export.rb") unless defined?(Rails)

ABSENCE_PATTERNS = {
  "DATA_NOT_AVAILABLE"         => /DATA_NOT_AVAILABLE/,
  "REQUIRE_FIELD_VERIFICATION" => /REQUIRE_FIELD_VERIFICATION/
}.freeze
REFORMULATION_WINDOW = 10.minutes

def percentile(sorted_asc, pct)
  return nil if sorted_asc.empty?

  idx = ((pct / 100.0) * (sorted_asc.size - 1)).round
  sorted_asc[idx]
end

date  = ARGV.first.presence ? Date.parse(ARGV.first) : Time.zone.today
range = date.in_time_zone.all_day

# ── Volume + cost by source ───────────────────────────────────────────────────
# Single pluck (no AR instantiation from DB); per-row cost reuses
# BedrockQuery#cost on unpersisted instances so pricing logic isn't duplicated.
rows = BedrockQuery.where(created_at: range).pluck(
  :source, :route, :latency_ms, :model_id,
  :input_tokens, :output_tokens, :cache_read_tokens, :cache_creation_tokens
)

volume_by_source = rows.group_by { |r| r[0] }.map do |source, group|
  cost = group.sum do |_source, _route, _latency_ms, model_id, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens|
    BedrockQuery.new(
      model_id:              model_id,
      input_tokens:          input_tokens,
      output_tokens:         output_tokens,
      cache_read_tokens:     cache_read_tokens,
      cache_creation_tokens: cache_creation_tokens
    ).cost
  end
  latencies = group.filter_map { |r| r[2] }
  {
    source:         source,
    count:          group.size,
    input_tokens:   group.sum { |r| r[4].to_i },
    output_tokens:  group.sum { |r| r[5].to_i },
    cost:           cost.round(6),
    avg_latency_ms: latencies.empty? ? nil : (latencies.sum.to_f / latencies.size).round(1)
  }
end

# ── Latency p50/p95/max for source=query, split by route ────────────────────
query_rows = rows.select { |r| r[0] == "query" }
query_latency_by_route = query_rows.group_by { |r| r[1] }.transform_values do |group|
  sorted = group.filter_map { |r| r[2] }.sort
  { count: sorted.size, p50: percentile(sorted, 50), p95: percentile(sorted, 95), max: sorted.max }
end

# ── DATA_NOT_AVAILABLE / REQUIRE_FIELD_VERIFICATION + reformulations ─────────
# The literal marker is guaranteed on prose-only absence answers by
# BedrockRagService#normalize_absence_semantics (Gate B); scanning
# conversation_history avoids re-deriving it from logs.
sessions_touched = ConversationSession
  .where(updated_at: range)
  .where("jsonb_array_length(conversation_history) > 0")

absence_counts       = Hash.new(0)
assistant_msg_count  = 0
reformulation_count  = 0
sessions_today       = []
absence_questions    = []
document_usage       = Hash.new { |h, k| h[k] = { sessions: 0, name: nil, source_uri: nil, kb_document_id: nil } }

sessions_touched.find_each do |session|
  history = session.conversation_history
  assistant_entries = history.select { |m| m["role"] == "assistant" }
  assistant_msg_count += assistant_entries.size
  ABSENCE_PATTERNS.each do |label, pattern|
    absence_counts[label] += assistant_entries.count { |m| m["content"].to_s.match?(pattern) }
  end

  indexed = history.each_with_index.to_a
  indexed.each do |message, index|
    next unless message["role"] == "assistant"

    matched_label = ABSENCE_PATTERNS.find { |_label, pattern| message["content"].to_s.match?(pattern) }&.first
    next unless matched_label

    previous_user = history[0...index].reverse.find { |m| m["role"] == "user" }
    absence_questions << {
      session_id:       session.id,
      account_id:       session.account_id,
      marker:           matched_label,
      user_question:    previous_user&.dig("content"),
      assistant_answer: message["content"],
      answered_at:      message["ts"]
    }
  end

  user_entries = indexed.select { |m, _i| m["role"] == "user" }
  user_entries.each_cons(2) do |(u1, i1), (u2, i2)|
    t1 = Time.zone.parse(u1["ts"].to_s) rescue nil
    t2 = Time.zone.parse(u2["ts"].to_s) rescue nil
    next unless t1 && t2 && range.cover?(t2)
    next unless (t2 - t1) < REFORMULATION_WINDOW

    between           = history[(i1 + 1)...i2] || []
    assistant_between = between.select { |m| m["role"] == "assistant" }
    useful = assistant_between.any? do |m|
      ABSENCE_PATTERNS.values.none? { |pattern| m["content"].to_s.match?(pattern) }
    end
    reformulation_count += 1 unless useful
  end

  Array(session.active_entities).each do |name, meta|
    source_uri = meta["source_uri"].presence
    kb_id      = meta["kb_document_id"].presence
    key        = source_uri || kb_id || name
    next if key.blank?

    document_usage[key][:sessions] += 1
    document_usage[key][:name] ||= meta["canonical_name"].presence || name
    document_usage[key][:source_uri] ||= source_uri
    document_usage[key][:kb_document_id] ||= kb_id
  end

  sessions_today << { id: session.id, account_id: session.account_id, history: history }
end

top_documents_used = document_usage.values
  .sort_by { |row| [ -row[:sessions], row[:name].to_s ] }
  .first(20)

# ── Manuals readiness snapshot (not date-scoped — pilot onboarding check) ───
manual_batches = WebManualBatch.order(:id).pluck(:id, :account_id, :status, :chunks_count, :filename).map do |id, account_id, status, chunks_count, filename|
  { id: id, account_id: account_id, status: status, chunks_count: chunks_count, filename: filename }
end

output = {
  date:                              date.to_s,
  timezone:                          Time.zone.name,
  generated_at:                      Time.current.iso8601,
  volume_by_source:                  volume_by_source,
  query_latency_by_route:            query_latency_by_route,
  data_not_available_count:         absence_counts["DATA_NOT_AVAILABLE"],
  require_field_verification_count: absence_counts["REQUIRE_FIELD_VERIFICATION"],
  absence_questions:                absence_questions.first(50),
  assistant_message_count:          assistant_msg_count,
  reformulation_count:              reformulation_count,
  top_documents_used:               top_documents_used,
  sessions_today:                   sessions_today,
  manual_batches:                   manual_batches
}

puts JSON.generate(output)
