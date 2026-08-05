# frozen_string_literal: true

class PilotValueReport
  NOT_AVAILABLE = "n/a"

  def initialize(report)
    @report = report.to_h.deep_stringify_keys
  end

  def as_json(*)
    {
      auditability: auditability,
      precision_and_safety: precision_and_safety,
      value_capture: value_capture,
      knowledge_gaps: knowledge_gaps,
      adoption: adoption
    }
  end

  private

  attr_reader :report

  def interactions
    @interactions ||= Array(report.dig("interactions", "by_correlation"))
  end

  def answered
    @answered ||= interactions.select { |interaction| interaction["outcome"] == "answered" }
  end

  def auditability
    audited = answered.count do |interaction|
      interaction_documents(interaction).any? && interaction_pages(interaction).any?
    end
    documents = answered.flat_map { |interaction| interaction_documents(interaction) }.uniq.sort
    pages = answered.flat_map { |interaction| interaction_pages(interaction) }.uniq.sort_by(&:to_s)

    {
      answered_interactions: answered.size,
      audited_answers: audited,
      audited_answer_rate: ratio(audited, answered.size),
      documents_referenced: documents.size,
      document_names: documents,
      pages_referenced: pages.size,
      page_numbers: pages,
      citations_per_answer: ratio(answered.sum { |interaction| interaction["citations_count"].to_i }, answered.size)
    }
  end

  def precision_and_safety
    reviewed = interactions.select { |interaction| interaction["correct_answer"].present? }
    correct = reviewed.count { |interaction| affirmative?(interaction["correct_answer"]) }
    verification_status = reviewed.empty? ? "REQUIRES_HUMAN_REVIEW" : "available"

    {
      abstentions: interactions.count { |interaction| interaction["outcome"] == "abstained" },
      abstention_rate: ratio(interactions.count { |interaction| interaction["outcome"] == "abstained" }, interactions.size),
      evidence_present_rate: ratio(answered.count { |interaction| interaction["evidence_present"] == true }, answered.size),
      attribution_dropped: attribution_dropped,
      failures: Array(report.dig("interactions", "failures")),
      verified_correct_rate: reviewed.empty? ? NOT_AVAILABLE : ratio(correct, reviewed.size),
      verification_status: verification_status,
      reviewed_interactions: reviewed.size,
      verified_correct_interactions: reviewed.empty? ? NOT_AVAILABLE : correct
    }
  end

  def value_capture
    costs = answered.filter_map do |interaction|
      interaction["attributed_cost_usd"] if interaction.key?("attributed_cost_usd")
    end
    latencies = answered_latencies

    {
      cost_per_answered_interaction_usd: costs.size == answered.size && answered.any? ?
        (costs.sum.to_f / answered.size).round(6) : NOT_AVAILABLE,
      answer_time_p50_s: seconds(percentile(latencies, 50)),
      answer_time_p95_s: seconds(percentile(latencies, 95)),
      estimated_cost_avoided: value_or_na(report.dig("technical_and_cost", "totals", "estimated_cost_avoided")),
      visual_llm_calls_avoided: value_or_na(report.dig("technical_and_cost", "totals", "visual_llm_calls_avoided")),
      prompt_cache_tokens_saved: prompt_cache_tokens
    }
  end

  def knowledge_gaps
    gaps = report.fetch("knowledge_gap_signals", {})
    absence_questions = Array(gaps["absence_questions"])
    abstentions = interactions.select { |interaction| interaction["outcome"] == "abstained" }.map do |interaction|
      {
        correlation_id: interaction["correlation_id"],
        question: interaction.dig("audit", "question") || interaction["question"],
        documents: interaction_documents(interaction),
        pages: interaction_pages(interaction)
      }
    end

    {
      by_signal: {
        abstained: abstentions.size,
        data_not_available: value_or_na(gaps["data_not_available_count"]),
        require_field_verification: value_or_na(gaps["require_field_verification_count"])
      },
      abstentions: abstentions,
      data_not_available: absence_questions.select do |entry|
        entry["marker"].to_s == "DATA_NOT_AVAILABLE"
      end,
      grouped_absence_markers: absence_questions.group_by { |entry| entry["marker"].presence || "UNKNOWN" }
        .transform_values(&:size)
    }
  end

  def adoption
    dates = Array(report.dig("repeat_usage", "queries_by_user_day"))
      .filter_map { |entry| entry["date"].presence }
      .reject { |date| date == "unknown" }
      .uniq

    {
      active_users: value_or_na(report.dig("interactions", "active_users") || report.dig("adoption_signals", "active_users")),
      returning_users: value_or_na(report.dig("interactions", "returning_users")),
      repeated_questions: value_or_na(report.dig("interactions", "repeated_questions_count")),
      sessions: value_or_na(report.dig("adoption_signals", "sessions")),
      active_days: dates.empty? ? NOT_AVAILABLE : dates.size
    }
  end

  def interaction_documents(interaction)
    audit_citations = Array(interaction.dig("audit", "citations"))
    (
      Array(interaction["documents"]) +
      audit_citations.filter_map { |citation| citation["title"].presence || citation["filename"].presence } +
      Array(interaction["citation_titles"])
    ).filter_map { |document| document.to_s.sub(/\s+—\s+p\.\s*\d+\z/, "").presence }.uniq
  end

  def interaction_pages(interaction)
    audit_pages = Array(interaction.dig("audit", "citations")).filter_map { |citation| citation["page"] }
    title_pages = Array(interaction["citation_titles"]).filter_map do |title|
      title.to_s[/—\s+p\.\s*(\d+)/, 1]&.to_i
    end
    (Array(interaction["pages"]) + audit_pages + title_pages).compact.uniq
  end

  def attribution_dropped
    summary = report.dig("technical_and_cost", "evidence_route_summary") || {}
    return summary["attribution_dropped"] if summary.key?("attribution_dropped")

    values = interactions.filter_map do |interaction|
      interaction["attribution_dropped"] if interaction.key?("attribution_dropped")
    end
    values.empty? ? NOT_AVAILABLE : values.sum(&:to_i)
  end

  def answered_latencies
    answered_ids = answered.filter_map { |interaction| interaction["correlation_id"].presence }
    Array(report.dig("technical_and_cost", "interaction_trace"))
      .select { |trace| answered_ids.include?(trace["correlation_id"]) && trace["latency_ms"].present? }
      .group_by { |trace| trace["correlation_id"] }
      .values
      .map { |traces| traces.sum { |trace| trace["latency_ms"].to_i } }
      .sort
  end

  def prompt_cache_tokens
    totals = report.dig("technical_and_cost", "totals") || {}
    return totals["cache_read_tokens"] if totals.key?("cache_read_tokens")

    rows = Array(report.dig("technical_and_cost", "model_usage"))
    values = rows.filter_map { |row| row["cache_read_tokens"] if row.key?("cache_read_tokens") }
    values.empty? ? NOT_AVAILABLE : values.sum(&:to_i)
  end

  def affirmative?(value)
    %w[1 correct correcto si sí true yes].include?(value.to_s.strip.downcase)
  end

  def ratio(numerator, denominator)
    return NOT_AVAILABLE if denominator.to_i.zero?

    (numerator.to_f / denominator).round(4)
  end

  def percentile(values, percent)
    return nil if values.empty?

    values[((percent / 100.0) * (values.size - 1)).round]
  end

  def seconds(milliseconds)
    milliseconds.nil? ? NOT_AVAILABLE : (milliseconds / 1000.0).round(3)
  end

  def value_or_na(value)
    value.nil? ? NOT_AVAILABLE : value
  end
end
