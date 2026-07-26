# frozen_string_literal: true

module Rag
  # Evaluates recorded RAG answers against an explicit per-question rubric.
  # Required, optional, and penalized claims remain separate so a safe
  # reformulation is not scored like a missing critical fact.
  class BenchmarkRubricEvaluator
    PENALTY_WEIGHTS = {
      "critical" => 5,
      "technical_important" => 3,
      "secondary" => 1,
      "excess_without_impact" => 0.5
    }.freeze

    def initialize(rubric:, payload:)
      @rubric = rubric.deep_stringify_keys
      @payload = payload.deep_stringify_keys
    end

    def evaluate
      results_by_id = Array(@payload["results"]).index_by { |result| result["id"] }
      cases = Array(@rubric["cases"]).map do |definition|
        evaluate_case(definition, results_by_id[definition["id"]])
      end

      {
        "rubric_version" => @rubric["version"],
        "benchmark_run_id" => @payload["run_id"],
        "passed" => cases.all? { |result| result["passed"] },
        "summary" => {
          "cases" => cases.size,
          "passed" => cases.count { |result| result["passed"] },
          "failed" => cases.count { |result| !result["passed"] },
          "score" => cases.sum { |result| result["score"] }.round(2),
          "max_score" => cases.sum { |result| result["max_score"] }.round(2)
        },
        "cases" => cases
      }
    end

    private

    def evaluate_case(definition, result)
      answer = result&.fetch("answer", "").to_s
      required = checks(definition["required"], answer)
      optional = checks(definition["optional"], answer)
      penalized = checks(definition["penalized"], answer, matched_is_pass: false)
      missing_result = result.nil?
      citation_required = definition.fetch(
        "citation_required",
        @rubric.fetch("citation_required", false)
      )
      citation_present = Array(result&.fetch("citations", nil)).any?
      citation_passed = !citation_required || citation_present
      max_score = required.size * 2 + optional.size + (citation_required ? 2 : 0)
      score = required.count { |check| check["matched"] } * 2 +
        optional.count { |check| check["matched"] } -
        penalized.select { |check| check["matched"] }.sum { |check| penalty_weight(check["severity"]) }
      score += 2 if citation_required && citation_present
      passed = !missing_result &&
        citation_passed &&
        required.all? { |check| check["matched"] } &&
        penalized.none? { |check| check["matched"] }

      {
        "id" => definition["id"],
        "category" => definition["category"],
        "severity" => definition["severity"],
        "source_pages" => definition["source_pages"],
        "passed" => passed,
        "score" => score.clamp(0, max_score).round(2),
        "max_score" => max_score,
        "missing_result" => missing_result,
        "citation_required" => citation_required,
        "citation_present" => citation_present,
        "citation_passed" => citation_passed,
        "required" => required,
        "optional" => optional,
        "penalized" => penalized
      }
    end

    def checks(definitions, answer, matched_is_pass: true)
      Array(definitions).map do |definition|
        matched = regexp(definition["pattern"]).match?(answer)
        {
          "label" => definition["label"],
          "matched" => matched,
          "passed" => matched_is_pass ? matched : !matched,
          "severity" => definition["severity"]
        }.compact
      end
    end

    def regexp(pattern)
      Regexp.new(pattern.to_s, Regexp::IGNORECASE | Regexp::MULTILINE)
    rescue RegexpError => e
      raise ArgumentError, "Invalid rubric pattern #{pattern.inspect}: #{e.message}"
    end

    def penalty_weight(severity)
      PENALTY_WEIGHTS.fetch(severity.to_s, PENALTY_WEIGHTS["secondary"])
    end
  end
end
