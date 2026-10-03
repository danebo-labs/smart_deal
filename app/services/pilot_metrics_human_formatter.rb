# frozen_string_literal: true

# Pure presentation layer over PilotMetricsReport#as_json. Renders the same
# hash `script/pilot_metrics_export.rb` already JSON.generate's — never
# recomputes metrics, never touches PilotMetricsReport/PilotUsageLog, and
# never mutates the input hash (the caller may still JSON.generate it).
class PilotMetricsHumanFormatter
  def initialize(report)
    @report = report
  end

  def to_s
    [
      header_section,
      totals_section,
      adoption_section,
      interactions_section,
      turns_section,
      repeat_usage_section,
      evidence_route_section,
      evidence_quality_section,
      knowledge_gap_section,
      commercial_outcomes_section,
      data_quality_section,
      per_user_table,
      per_account_table
    ].compact.join("\n\n")
  end

  private

  attr_reader :report

  def header_section
    lines = [ "Pilot metrics — #{report[:date] || 'n/a'} (#{report[:timezone] || 'n/a'})" ]
    lines << "Generated at: #{report[:generated_at]}" if report[:generated_at]
    lines.join("\n")
  end

  def totals_section
    totals = report.dig(:technical_and_cost, :totals)
    return nil unless totals

    lines = [ "== Totals ==" ]
    lines << "RAG LLM calls: #{num(totals[:rag_llm_calls])}   Visual LLM calls: #{num(totals[:visual_llm_calls])}"
    lines << "Photo cache hits: #{num(totals[:photo_cache_hits])} (hit rate: #{pct(totals[:photo_cache_hit_rate])})   " \
             "Visual calls avoided: #{num(totals[:visual_llm_calls_avoided])}"
    lines << "Input tokens: #{num(totals[:input_tokens])}   Output tokens: #{num(totals[:output_tokens])}"
    lines << "Attributed cost: #{money(totals[:attributed_cost_usd])}   " \
             "Provider usage: #{money(totals[:provider_usage_usd])}   Estimated: #{money(totals[:estimated_usd])}"
    lines << "Estimated cost avoided: #{money(totals[:estimated_cost_avoided])}"
    lines.join("\n")
  end

  def adoption_section
    adoption = report[:adoption_signals]
    return nil unless adoption

    lines = [ "== Adoption ==" ]
    lines << "Active users: #{num(adoption[:active_users])}   Active accounts: #{num(adoption[:active_accounts])}   " \
             "Sessions: #{num(adoption[:sessions])}"
    lines << "User messages: #{num(adoption[:user_messages])}   Assistant messages: #{num(adoption[:assistant_messages])}"
    lines << "RAG LLM calls: #{num(adoption[:rag_llm_calls])}   Photo requests: #{num(adoption[:photo_requests])}"
    lines.join("\n")
  end

  def interactions_section
    interactions = report[:interactions]
    return nil unless interactions

    lines = [ "== Interactions ==" ]
    return (lines << "status: #{interactions[:status]}").join("\n") if interactions[:status] != "available"

    lines << "Total: #{num(interactions[:total])}   LLM calls attributed: #{num(interactions[:llm_calls_attributed])}   " \
             "LLM calls in range: #{num(interactions[:llm_calls_in_range])}   " \
             "Zero-LLM interactions: #{num(interactions[:zero_llm_call_interactions])}"
    verification = interactions[:verification].to_h
    lines << "Verification: #{verification[:status]} — #{Array(verification[:fields]).join(', ')}"
    lines << "Contract checks: #{tally_line(interactions[:contract_checks])}"
    lines << "By outcome: #{tally_line(interactions[:by_outcome])}"
    lines << "Active users: #{num(interactions[:active_users])}   " \
             "Returning users (2+ days): #{num(interactions[:returning_users])}   " \
             "Unattributed: #{num(interactions[:unattributed_count])}"
    lines << "Repeated questions: #{num(interactions[:repeated_questions_count])}"
    Array(interactions[:top_repeated_questions]).first(5).each do |row|
      lines << "  user #{num(row[:user_id])} · #{short(row[:question_sha256])} · #{num(row[:count])}x"
    end
    failures = Array(interactions[:failures])
    lines << "Failures: #{failures.size}"
    failures.first(5).each do |failure|
      lines << "  #{failure[:correlation_id]} · route #{failure[:route]} · stage #{failure[:stage]} · error #{failure[:error_class]}"
    end
    lines.join("\n")
  end

  def turns_section
    rows = Array(report.dig(:interactions, :by_correlation))
    cards = rows.filter_map { |row| row if row[:field_companion].present? }
    return nil if cards.empty?

    lines = [ "== Turns ==" ]
    cards.each { |row| lines << turn_card(row) }
    lines.join("\n\n")
  end

  def turn_card(row)
    trace = row[:field_companion]
    lines = [ "TURN #{row[:correlation_id]}" ]
    lines << "session=#{row[:conversation_session_id]}" if row[:conversation_session_id]
    lines << "episode=#{trace[:episode_id]}" if trace[:episode_id]
    lines << "turn=#{trace[:interpreter_move]}" if trace[:interpreter_move]
    if trace[:goal]
      lines << "goal:"
      lines << "  text: #{trace[:goal][:text]}"
      lines << "  source_correlation_id: #{trace[:goal][:source_correlation_id]}" if trace[:goal][:source_correlation_id]
    end
    if trace[:photo]
      photo = trace[:photo]
      lines << "photo:"
      lines << "  field_photo_id=#{photo[:field_photo_id]}" if photo[:field_photo_id]
      lines << "  active=#{photo[:active_photo_id]}" if photo[:active_photo_id]
      lines << "  relevance=#{photo[:relevance_to_goal]}" if photo[:relevance_to_goal]
      lines << "  continuity=#{photo[:continuity_action]}" if photo[:continuity_action]
      lines << "  vision=#{photo[:vision]}" if photo[:vision]
    end
    if trace[:visual_identity]
      visual = trace[:visual_identity]
      lines << "visual_identity:"
      lines << "  #{visual[:manufacturer]} / #{visual[:model]}"
      lines << "  persistence=#{visual[:persistence]}"
    end
    Array(trace[:identity_promotions]).each do |promotion|
      lines << "identity_promotion:"
      lines << "  result=#{promotion[:result]}"
      lines << "  reason=#{promotion[:outcome_reason]}" if promotion[:outcome_reason]
      lines << "  relevance=#{promotion[:relevance_to_goal]}" if promotion[:relevance_to_goal]
      lines << "  before=#{promotion[:identity_before]}" if promotion[:identity_before]
      lines << "  after=#{promotion[:identity_after]}" if promotion[:identity_after]
      lines << "  conflict=#{promotion[:identity_conflict]}" unless promotion[:identity_conflict].nil?
    end
    if trace[:retrieval_identity]
      retrieval = trace[:retrieval_identity]
      lines << "retrieval_identity:"
      lines << "  #{retrieval[:manufacturer]} / #{retrieval[:model]}"
      lines << "  facts=#{retrieval[:identity_after]}" if retrieval[:identity_after]
    end
    if trace[:document_identity_scope]
      scope = trace[:document_identity_scope]
      lines << "document_identity_scope:"
      lines << "  status=#{scope[:result]}" if scope[:result]
      lines << "  reason=#{scope[:outcome_reason]}" if scope[:outcome_reason]
      lines << "  needles=#{Array(scope[:scope_needles]).join(',')}" if scope[:scope_needles]
      lines << "  conflict=#{scope[:identity_conflict]}" unless scope[:identity_conflict].nil?
    end
    if trace[:open_retrieval]
      open = trace[:open_retrieval]
      line = "open_retrieval=#{open[:result]}"
      line = "#{line} reason=#{open[:outcome_reason]}" if open[:outcome_reason]
      lines << line
    end
    if trace[:retrieval]
      lines << "chunks: kept=#{trace[:retrieval][:results_count]} rejected=#{trace[:retrieval][:rejected_result_count]}"
    end
    Array(trace[:stale_case_writes]).each do |stale|
      lines << "stale_case_write: writer=#{stale[:writer]} expected=#{stale[:expected_episode_id]} live=#{stale[:episode_id]}"
    end
    lines << "execution_path: #{Array(trace[:execution_path]).join(' -> ')}" if trace[:execution_path].present?
    lines << "citations=#{row[:citations_count]}" unless row[:citations_count].nil?
    lines << "generation_mode=#{row[:generation_mode]}" if row[:generation_mode]
    lines.join("\n")
  end

  def repeat_usage_section
    repeat = report[:repeat_usage]
    return nil unless repeat

    lines = [ "== Repeat usage ==" ]
    return (lines << "status: #{repeat[:status]}").join("\n") if repeat[:status] != "available"

    lines << "Users with 2+ active days: #{num(repeat[:users_with_multiple_days])}"
    lines << "Repeat questions: #{num(repeat[:repeat_questions_count])}"
    Array(repeat[:top_repeated_questions]).first(5).each do |row|
      lines << "  user #{num(row[:user_id])} · #{short(row[:question_sha256])} · #{num(row[:count])}x"
    end
    lines.join("\n")
  end

  def evidence_route_section
    summary = report.dig(:technical_and_cost, :evidence_route_summary)
    return nil unless summary

    lines = [ "== Evidence route summary ==" ]
    return (lines << "status: #{summary[:status]}").join("\n") if summary[:status] != "available"

    lines << "Outcomes: #{tally_line(summary[:responses_by_outcome])}"
    lines << "Generation modes: #{tally_line(summary[:responses_by_generation_mode])}"
    lines << "Abstention rate: #{pct(summary[:abstention_rate])}   Ambiguity detected: #{num(summary[:ambiguity_detected_count])}"
    Array(summary.dig(:latency_stages)&.keys).each do |stage|
      stats = summary.dig(:latency_stages, stage)
      lines << "  #{stage}: p50=#{ms(stats[:p50])} p95=#{ms(stats[:p95])} max=#{ms(stats[:max])}"
    end
    lines << "Tokens in/out: #{num(summary[:tokens_in])}/#{num(summary[:tokens_out])}   " \
             "(avg/query: #{num(summary[:avg_tokens_in_per_query])}/#{num(summary[:avg_tokens_out_per_query])})"
    lines.join("\n")
  end

  def evidence_quality_section
    quality = report[:evidence_quality]
    return nil unless quality

    lines = [ "== Evidence quality ==" ]
    return (lines << "status: #{quality[:status]}").join("\n") if quality[:status] != "available"

    lines << "Records: #{num(quality[:records])}   Evidence present: #{num(quality[:evidence_present])}   " \
             "Evidence missing: #{num(quality[:evidence_missing])}"
    lines << "Citations: #{num(quality[:citations])}   Retrieved chunks: #{num(quality[:retrieved_chunks])}"
    lines << "Top referenced documents: #{tally_line(quality[:referenced_documents])}"
    if quality[:recent_questions]
      lines << "Recent questions (raw text, opt-in):"
      quality[:recent_questions].first(10).each do |entry|
        evidence = entry[:evidence_present] ? "yes" : "no"
        lines << "  [#{entry[:occurred_at]}] user #{num(entry[:user_id])} · #{entry[:correlation_id]} · " \
                 "evidence:#{evidence} · \"#{entry[:question]}\""
      end
    end
    lines.join("\n")
  end

  def knowledge_gap_section
    gaps = report[:knowledge_gap_signals]
    return nil unless gaps

    lines = [ "== Knowledge gap signals ==" ]
    lines << "DATA_NOT_AVAILABLE: #{num(gaps[:data_not_available_count])}   " \
             "REQUIRE_FIELD_VERIFICATION: #{num(gaps[:require_field_verification_count])}   " \
             "Reformulations: #{num(gaps[:reformulation_count])}"
    lines.join("\n")
  end

  def commercial_outcomes_section
    outcomes = report[:commercial_outcomes]
    return nil unless outcomes

    "== Commercial outcomes ==\nstatus: #{outcomes[:status]}"
  end

  def data_quality_section
    quality = report[:data_quality]
    return nil unless quality

    lines = [ "== Data quality ==" ]
    lines << "usage_log: #{quality[:usage_log]}"
    lines << "messages_without_timestamp_excluded: #{num(quality[:messages_without_timestamp_excluded])}   " \
             "unattributed_messages: #{num(quality[:unattributed_messages])}"
    Array(quality[:limits]).each { |limit| lines << "  - #{limit}" }
    lines.join("\n")
  end

  def per_user_table
    users = report.dig(:technical_and_cost, :per_user)
    return nil if users.blank?

    rows = users.map do |row|
      [
        row[:label].to_s, num(row[:queries]).to_s, num(row[:photo_requests]).to_s,
        num(row[:photo_cache_hits]).to_s, money(row[:attributed_cost_usd]), ms(row[:latency_p50_ms]), ms(row[:latency_p95_ms])
      ]
    end
    render_table(
      "== Per user (#{users.size}) ==",
      %w[label queries photos cache_hits cost p50 p95],
      rows
    )
  end

  def per_account_table
    accounts = report.dig(:technical_and_cost, :per_account)
    return nil if accounts.blank?

    rows = accounts.map do |row|
      [
        row[:account_name].to_s.presence || row[:account_id].to_s, num(row[:total_queries]).to_s,
        num(row[:total_photo_requests]).to_s, num(row[:photo_cache_hits]).to_s,
        money(row[:attributed_cost_usd]), ms(row[:latency_p50_ms]), ms(row[:latency_p95_ms])
      ]
    end
    render_table(
      "== Per account (#{accounts.size}) ==",
      %w[account queries photos cache_hits cost p50 p95],
      rows
    )
  end

  def render_table(title, headers, rows)
    widths = headers.each_with_index.map { |h, i| ([ h.length ] + rows.map { |r| r[i].length }).max }
    header_line = headers.each_with_index.map { |h, i| h.ljust(widths[i]) }.join("  ")
    separator = widths.map { |w| "-" * w }.join("  ")
    body = rows.map { |row| row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ") }
    ([ title, header_line, separator ] + body).join("\n")
  end

  def tally_line(hash)
    return "n/a" if hash.blank?

    hash.map { |key, count| "#{key}=#{count}" }.join(", ")
  end

  def short(value)
    value.present? ? "#{value.to_s[0, 10]}…" : "n/a"
  end

  def num(value)
    value.nil? ? "n/a" : value
  end

  def ms(value)
    value.nil? ? "n/a" : "#{value}ms"
  end

  def money(value)
    value.nil? ? "n/a" : format("$%.6f", value)
  end

  def pct(value)
    value.nil? ? "n/a" : format("%.1f%%", value * 100)
  end
end
