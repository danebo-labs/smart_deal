# frozen_string_literal: true

require "test_helper"

class Rag::BenchmarkRubricEvaluatorTest < ActiveSupport::TestCase
  test "separates required optional and penalized claims" do
    rubric = {
      version: "test-v1",
      cases: [
        {
          id: "tpr70",
          category: "visual",
          severity: "critical",
          source_pages: [ 11 ],
          required: [
            { label: "EPC", pattern: "\\bEPC\\b" },
            { label: "B8", pattern: "\\bB8\\b" }
          ],
          optional: [ { label: "page", pattern: "p\\. 11" } ],
          penalized: [
            { label: "B7", pattern: "\\bB7\\b", severity: "critical" }
          ]
        }
      ]
    }
    payload = {
      run_id: "run-1",
      results: [
        {
          id: "tpr70",
          answer: "EPC está en B8, p. 11.",
          citations: [ { title: "SEGURIDADES — p. 11" } ]
        }
      ]
    }

    evaluation = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload).evaluate
    result = evaluation.fetch("cases").first

    assert evaluation.fetch("passed")
    assert result.fetch("passed")
    assert_equal 5, result.fetch("score")
    assert result.fetch("required").all? { |check| check.fetch("matched") }
    assert_not result.fetch("penalized").first.fetch("matched")
  end

  test "fails a textually correct answer when the rubric requires a real citation" do
    rubric = {
      version: "test-v1",
      citation_required: true,
      cases: [
        {
          id: "tpr70",
          category: "visual",
          severity: "critical",
          source_pages: [ 11 ],
          required: [ { label: "EPC", pattern: "\\bEPC\\b" } ],
          optional: [],
          penalized: []
        }
      ]
    }
    payload = {
      results: [
        { id: "tpr70", answer: "EPC es un LED de la serie de cerrojos de cabina.", citations: [] }
      ]
    }

    result = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload)
      .evaluate
      .fetch("cases")
      .first

    assert_not result.fetch("passed")
    assert result.fetch("citation_required")
    assert_not result.fetch("citation_present")
    assert_not result.fetch("citation_passed")
  end

  test "source_page_cited passes when a citation's structured page matches source_pages" do
    rubric = {
      version: "test-v1",
      cases: [
        {
          id: "tpr70",
          category: "visual",
          severity: "critical",
          source_pages: [ 46 ],
          required: [],
          optional: [],
          penalized: []
        }
      ]
    }
    payload = {
      results: [
        { id: "tpr70", answer: "EPC está en B8.", citations: [ { page: 46, title: "SEGURIDADES — p. 46" } ] }
      ]
    }

    result = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload)
      .evaluate.fetch("cases").first

    assert result.fetch("source_page_required"), "source_page_required defaults to true when source_pages is present"
    assert result.fetch("source_page_cited")
    assert result.fetch("passed")
  end

  test "source_page_cited fails when the only citation is the near-duplicate page" do
    rubric = {
      version: "test-v1",
      cases: [
        {
          id: "tpr70",
          category: "visual",
          severity: "critical",
          source_pages: [ 46 ],
          required: [],
          optional: [],
          penalized: []
        }
      ]
    }
    payload = {
      results: [
        { id: "tpr70", answer: "EPC está en B8.", citations: [ { page: 79, title: "SEGURIDADES — p. 79" } ] }
      ]
    }

    result = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload)
      .evaluate.fetch("cases").first

    assert_not result.fetch("source_page_cited")
    assert_not result.fetch("passed"), "a citation to the duplicate page must fail the case even if every other check passes"
  end

  test "source_page_cited falls back to parsing the title when page is nil" do
    rubric = {
      version: "test-v1",
      cases: [
        {
          id: "tpr70",
          category: "visual",
          severity: "critical",
          source_pages: [ 46 ],
          required: [],
          optional: [],
          penalized: []
        }
      ]
    }
    payload = {
      results: [
        { id: "tpr70", answer: "EPC está en B8.", citations: [ { page: nil, title: "SEGURIDADES 1.1-1 — p. 46" } ] }
      ]
    }

    result = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload)
      .evaluate.fetch("cases").first

    assert result.fetch("source_page_cited")
    assert result.fetch("passed")
  end

  test "source_page_cited fails when there are no citations at all" do
    rubric = {
      version: "test-v1",
      cases: [
        {
          id: "tpr70",
          category: "visual",
          severity: "critical",
          source_pages: [ 46 ],
          required: [],
          optional: [],
          penalized: []
        }
      ]
    }
    payload = { results: [ { id: "tpr70", answer: "EPC está en B8.", citations: [] } ] }

    result = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload)
      .evaluate.fetch("cases").first

    assert_not result.fetch("source_page_cited")
    assert_not result.fetch("passed")
  end

  test "source_page_required: false skips the page check even with a wrong-page citation" do
    rubric = {
      version: "test-v1",
      cases: [
        {
          id: "tpr70",
          category: "visual",
          severity: "critical",
          source_pages: [ 46 ],
          source_page_required: false,
          required: [],
          optional: [],
          penalized: []
        }
      ]
    }
    payload = {
      results: [
        { id: "tpr70", answer: "EPC está en B8.", citations: [ { page: 79, title: "SEGURIDADES — p. 79" } ] }
      ]
    }

    result = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload)
      .evaluate.fetch("cases").first

    assert_not result.fetch("source_page_required")
    assert result.fetch("source_page_cited"), "opted-out cases report the check as satisfied (not applicable)"
    assert result.fetch("passed")
  end

  test "fails and applies severity penalty when a forbidden claim appears" do
    rubric = {
      version: "test-v1",
      cases: [
        {
          id: "tpr70",
          category: "visual",
          severity: "critical",
          source_pages: [ 11 ],
          required: [ { label: "EPC", pattern: "\\bEPC\\b" } ],
          optional: [],
          penalized: [
            { label: "B7", pattern: "\\bB7\\b", severity: "critical" }
          ]
        }
      ]
    }
    payload = { results: [ { id: "tpr70", answer: "EPC está en B7." } ] }

    evaluation = Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload).evaluate

    assert_not evaluation.fetch("passed")
    assert_equal 0, evaluation.dig("cases", 0, "score")
    assert evaluation.dig("cases", 0, "penalized", 0, "matched")
  end
end
