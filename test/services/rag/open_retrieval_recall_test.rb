# frozen_string_literal: true

require "test_helper"

class Rag::OpenRetrievalRecallTest < ActiveSupport::TestCase
  test "legacy and pilot catalog rows are a backfill gap until danebo_general" do
    legacy = classify("account_id" => "1", "document_id" => "em3000", "display_name" => "EM3000")
    pilot = classify("account_id" => "3", "document_id" => "lce", "display_name" => "LCE")
    tagged = classify(
      "account_id" => "9", "document_id" => "tagged", "manual_corpus" => "general",
      "knowledge_scope" => "tenant_private"
    )

    [ legacy, pilot, tagged ].each do |row|
      assert row.historical
      assert_not row.current
      assert_equal "backfill_gap", row.disposition
    end
  end

  test "the owner index keeps its row and an explicit general is current for another index" do
    owned = Rag::OpenRetrievalRecall.classify(
      { "account_id" => "3", "document_id" => "own", "display_name" => "Own" },
      viewer_index: "3"
    )
    general = classify(
      "account_id" => "1", "document_id" => "shared", "display_name" => "Shared",
      "knowledge_scope" => "danebo_general"
    )

    assert owned.current
    assert_equal "retained", owned.disposition
    assert general.current
    assert_equal "retained", general.disposition
  end

  test "summary counts the catalog gap without calling a model" do
    summary = Rag::OpenRetrievalRecall.summarize(
      [
        { "account_id" => "1", "document_id" => "a" },
        { "account_id" => "3", "document_id" => "b" },
        { "account_id" => "5", "document_id" => "c", "knowledge_scope" => "danebo_general" }
      ],
      viewer_index: "5"
    )

    assert_equal 1, summary["current"]
    assert_equal 2, summary["backfill_gap"]
    assert_equal 1, summary["retained"]
  end

  private

  def classify(entry)
    Rag::OpenRetrievalRecall.classify(entry, viewer_index: "5")
  end
end
