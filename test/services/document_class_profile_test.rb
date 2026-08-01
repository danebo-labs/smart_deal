# frozen_string_literal: true

require "test_helper"

class DocumentClassProfileTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # classify
  # ---------------------------------------------------------------------------

  test "classify returns text_manual when no page carries a visual signal" do
    verdicts = {
      1 => { keep: true, visual_complexity: :none, has_visual_relations: false, component_count: 0 },
      2 => { keep: true, visual_complexity: :none, has_visual_relations: false, component_count: 0 }
    }

    result = DocumentClassProfile.classify(page_verdicts: verdicts)

    assert_equal :text_manual, result.document_class
    assert_equal 0.0, result.visual_page_fraction
  end

  test "classify ignores dropped pages when computing fractions" do
    verdicts = {
      1 => { keep: false, visual_complexity: :high, has_visual_relations: true, component_count: 9 },
      2 => { keep: true,  visual_complexity: :none, has_visual_relations: false, component_count: 0 }
    }

    result = DocumentClassProfile.classify(page_verdicts: verdicts)

    assert_equal :text_manual, result.document_class
    assert_equal 1, result.page_count
  end

  test "classify returns visual_technical when relational fraction clears the floor" do
    verdicts = (1..10).index_with do |i|
      if i <= 4
        { keep: true, visual_complexity: :high, has_visual_relations: true, component_count: 6 }
      else
        { keep: true, visual_complexity: :none, has_visual_relations: false, component_count: 0 }
      end
    end

    result = DocumentClassProfile.classify(page_verdicts: verdicts)

    assert_equal :visual_technical, result.document_class
    assert_in_delta 0.4, result.visual_page_fraction, 0.001
    assert_in_delta 1.0, result.relational_page_fraction, 0.001
  end

  test "classify returns photo_set for dense photographed components without drawn relations" do
    verdicts = (1..10).index_with do |i|
      if i <= 4
        { keep: true, visual_complexity: :moderate, has_visual_relations: false, component_count: 6 }
      else
        { keep: true, visual_complexity: :none, has_visual_relations: false, component_count: 0 }
      end
    end

    result = DocumentClassProfile.classify(page_verdicts: verdicts)

    assert_equal :photo_set, result.document_class
  end

  test "classify returns mixed when visual pages neither meet the relational nor the photo_set bar" do
    verdicts = (1..10).index_with do |i|
      if i <= 4
        { keep: true, visual_complexity: :moderate, has_visual_relations: false, component_count: 1 }
      else
        { keep: true, visual_complexity: :none, has_visual_relations: false, component_count: 0 }
      end
    end

    result = DocumentClassProfile.classify(page_verdicts: verdicts)

    assert_equal :mixed, result.document_class
  end

  test "classify defaults missing fields to none/false/0" do
    verdicts = { 1 => { keep: true } }

    result = DocumentClassProfile.classify(page_verdicts: verdicts)

    assert_equal :text_manual, result.document_class
  end

  test "classify on an empty verdict set returns text_manual with zero pages" do
    result = DocumentClassProfile.classify(page_verdicts: {})

    assert_equal :text_manual, result.document_class
    assert_equal 0, result.page_count
  end

  # ---------------------------------------------------------------------------
  # select_escalation_pages
  # ---------------------------------------------------------------------------

  test "select_escalation_pages ranks candidates by complexity_score descending under budget" do
    candidates = [
      { page_number: 1, complexity_score: 15 },
      { page_number: 2, complexity_score: 35 },
      { page_number: 3, complexity_score: 18 }
    ]

    escalated = DocumentClassProfile.select_escalation_pages(
      candidates: candidates, total_pages: 10, max_opus_page_fraction: 0.15
    )

    assert_equal Set[2], escalated
  end

  test "select_escalation_pages returns all candidates when the budget covers them" do
    candidates = [
      { page_number: 1, complexity_score: 15 },
      { page_number: 2, complexity_score: 35 }
    ]

    escalated = DocumentClassProfile.select_escalation_pages(
      candidates: candidates, total_pages: 10, max_opus_page_fraction: 1.0
    )

    assert_equal Set[1, 2], escalated
  end

  test "select_escalation_pages returns empty set when budget floors to zero" do
    candidates = [ { page_number: 1, complexity_score: 15 } ]

    escalated = DocumentClassProfile.select_escalation_pages(
      candidates: candidates, total_pages: 10, max_opus_page_fraction: 0.05
    )

    assert_empty escalated
  end

  test "select_escalation_pages returns empty set for no candidates" do
    escalated = DocumentClassProfile.select_escalation_pages(
      candidates: [], total_pages: 10, max_opus_page_fraction: 1.0
    )

    assert_empty escalated
  end
end
