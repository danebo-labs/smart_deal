# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"

class RagSeguridadesAnswerTransformer
  MODE = "partial_abstention"

  def initialize(payload:, locale: :es)
    @payload = payload.deep_dup
    @locale = locale
    @normalizer = BedrockRagService.allocate
    @processor = Rag::AnswerSafetyProcessor.new(locale:)
    @archived_cases = @payload.dig("evaluation", "cases").to_a.index_by { |item| item.fetch("id") }
  end

  def call
    rows = @payload.fetch("results").map { |result| transform_result(result) }
    mismatches = rows.reject { |row| row.fetch("fidelity_matched") }
    if mismatches.any?
      details = mismatches.map { |row| "#{row.fetch('id')}:#{row.fetch('fidelity_sha256')}" }
      raise ArgumentError, "Archived answer replay mismatch: #{details.join(', ')}"
    end

    [
      @payload,
      {
        "mode" => MODE,
        "fidelity_matches" => rows.count { |row| row.fetch("fidelity_matched") },
        "fidelity_total" => rows.size,
        "fidelity_rate" => "#{rows.count { |row| row.fetch('fidelity_matched') }}/#{rows.size}",
        "changed_results" => rows.count { |row| row.fetch("changed") },
        "partial_contract_appends" => rows.count { |row| row.fetch("partial_contract_appended") },
        "changed_ids" => rows.select { |row| row.fetch("changed") }.pluck("id"),
        "partial_contract_ids" =>
          rows.select { |row| row.fetch("partial_contract_appended") }.pluck("id"),
        "citations_unchanged" => true,
        "rows" => rows
      }
    ]
  end

  private

  def transform_result(result)
    archived_answer = result.fetch("answer")
    archived_case = @archived_cases[result.fetch("id")]
    internal_answer = result["internal_answer"]
    baseline_answer =
      if internal_answer.nil?
        archived_answer
      else
        render(internal_answer, result)
      end
    fidelity_matched = baseline_answer == archived_answer

    transformed_internal =
      if internal_answer.nil?
        nil
      else
        stripped, legacy_tail_removed = strip_legacy_tail(internal_answer)
        normalized = @normalizer.send(
          :normalize_absence_semantics,
          stripped,
          question: result.fetch("question"),
          locale: @locale,
          partial_contract: true
        )
        legacy_tail_removed && normalized == stripped ? internal_answer : normalized
      end
    transformed_answer =
      if transformed_internal.nil?
        archived_answer
      else
        render(transformed_internal, result)
      end
    result["answer"] = transformed_answer

    {
      "id" => result.fetch("id"),
      "generation_mode" => result["generation_mode"],
      "before_passed" => archived_case&.fetch("passed", nil),
      "before_required_satisfied" =>
        archived_case && archived_case.fetch("required").all? { |check| check.fetch("matched") },
      "fidelity_matched" => fidelity_matched,
      "fidelity_sha256" => {
        "archived" => Digest::SHA256.hexdigest(archived_answer),
        "replayed" => Digest::SHA256.hexdigest(baseline_answer)
      },
      "changed" => transformed_answer != archived_answer,
      "partial_contract_appended" =>
        partial_contract_appended?(internal_answer, transformed_internal),
      "answer_sha256" => {
        "before" => Digest::SHA256.hexdigest(archived_answer),
        "after" => Digest::SHA256.hexdigest(transformed_answer)
      }
    }
  end

  def render(internal_answer, result)
    @processor.call(
      internal_answer,
      evidence: result.fetch("chunks", []),
      require_cited_evidence: true
    )
  end

  def strip_legacy_tail(internal_answer)
    suffix = "\n\n#{I18n.t('rag.absence_total_contract', locale: @locale)}"
    return [ internal_answer, false ] unless internal_answer.end_with?(suffix)

    [ internal_answer.delete_suffix(suffix), true ]
  end

  def partial_contract_appended?(before, after)
    return false if before.nil? || after.nil?

    partial_suffix = "\n\n#{I18n.t('rag.absence_partial_contract', locale: @locale)}"
    stripped, = strip_legacy_tail(before)
    !stripped.match?(BedrockRagService::ABSENCE_MARKER_PATTERN) &&
      after.end_with?(partial_suffix)
  end
end

rubric_path = ENV.fetch(
  "RAG_SEGURIDADES_RUBRIC",
  Rails.root.join("script/fixtures/rag_seguridades_rubric.json").to_s
)
input_path = ENV.fetch(
  "RAG_SEGURIDADES_INPUT",
  Rails.root.join("tmp/rag_seguridades_benchmark.json").to_s
)
output_path = ENV.fetch(
  "RAG_SEGURIDADES_EVALUATION_OUTPUT",
  Rails.root.join("tmp/rag_seguridades_evaluation.json").to_s
)

rubric = JSON.parse(File.read(rubric_path))
payload = JSON.parse(File.read(input_path))

case_ids = ENV["RAG_SEGURIDADES_CASE_IDS"].to_s.split(",").map(&:strip).reject(&:empty?)
if case_ids.any?
  cases = rubric.fetch("cases").select { |definition| case_ids.include?(definition["id"]) }
  raise ArgumentError, "No rubric cases match RAG_SEGURIDADES_CASE_IDS=#{case_ids.join(",")}" if cases.empty?

  rubric = rubric.merge("cases" => cases)
end

transform_mode = ENV["RAG_SEGURIDADES_ANSWER_TRANSFORM"].to_s.presence
transform_report = nil
if transform_mode
  unless transform_mode == RagSeguridadesAnswerTransformer::MODE
    raise ArgumentError, "Unknown RAG_SEGURIDADES_ANSWER_TRANSFORM=#{transform_mode.inspect}"
  end

  payload, transform_report = RagSeguridadesAnswerTransformer.new(payload: payload).call
end

evaluation = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload).evaluate
if transform_report
  archived_cases = JSON.parse(File.read(input_path)).dig("evaluation", "cases").to_a.index_by do |item|
    item.fetch("id")
  end
  transform_report["case_deltas"] = evaluation.fetch("cases").map do |item|
    archived = archived_cases[item.fetch("id")]
    {
      "id" => item.fetch("id"),
      "before_passed" => archived&.fetch("passed", nil),
      "after_passed" => item.fetch("passed"),
      "before_score" => archived&.fetch("score", nil),
      "after_score" => item.fetch("score")
    }
  end
  transform_report["regressions"] = transform_report.fetch("case_deltas").count do |delta|
    delta.fetch("before_passed") && !delta.fetch("after_passed")
  end
  evaluation["answer_transform"] = transform_report
end

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate(evaluation))
summary = evaluation.fetch("summary").merge("passed" => evaluation.fetch("passed"))
summary["answer_transform"] = transform_report&.slice(
  "fidelity_rate", "changed_results", "partial_contract_appends", "regressions"
)
puts JSON.pretty_generate(summary.compact)
