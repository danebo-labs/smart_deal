# frozen_string_literal: true

require "test_helper"

class Rag::AssignmentSpendTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("assignment-spend")
    @path = File.join(@dir, "spend.json")
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  test "a second process sees attempts that were already reserved" do
    first = spend
    id = first.reserve!(ceiling_usd: "0.250000", model_id: "haiku", turn: 1)
    assert first.settle!(id, actual_usd: "0.010000", output_tokens: 10)

    second = spend
    snapshot = second.snapshot

    assert_equal 1, snapshot["attempts"]
    assert_equal "0.010000", snapshot["committed_usd"]
    assert_equal "0.000000", snapshot["held_usd"]

    error = assert_raises(Rag::AssignmentSpend::Stop) do
      second.reserve!(ceiling_usd: "1.000000", model_id: "sonnet", turn: 2)
    end

    assert_equal "assignment_spend", error.message
    assert_equal 1, second.snapshot["blocked"]
    assert_equal 1, second.snapshot["attempts"]
  end

  test "a call that does not leave releases the attempt" do
    book = spend(call_cap: 1)
    id = book.reserve!(ceiling_usd: "0.100000", model_id: "haiku", turn: 1)
    assert book.release!(id)

    assert_equal 0, book.snapshot["attempts"]
    assert book.reserve!(ceiling_usd: "0.100000", model_id: "haiku", turn: 1)
  end

  test "an unpriced error keeps the ceiling" do
    book = spend
    id = book.reserve!(ceiling_usd: "0.125000", model_id: "sonnet", turn: 1)
    assert book.keep!(id, error_class: "ServiceUnavailableException")

    snapshot = book.snapshot
    assert_equal 1, snapshot["attempts"]
    assert_equal "0.125000", snapshot["committed_usd"]
    assert_equal "0.000000", snapshot["held_usd"]
  end

  private

  def spend(call_cap: 2, cost_cap: "1")
    Rag::AssignmentSpend.new(path: @path, call_cap: call_cap, cost_cap_usd: cost_cap)
  end
end
