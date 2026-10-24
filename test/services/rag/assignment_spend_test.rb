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

  test "an error without usage keeps the ceiling as unknown and does not settle zero" do
    book = spend
    id = book.reserve!(ceiling_usd: "0.125000", model_id: "haiku", turn: 1)
    assert book.unknown!(id, error_class: "ServiceUnavailableException")

    snapshot = book.snapshot
    row = snapshot["entries"].last
    assert_equal 1, snapshot["attempts"]
    assert_equal "0.000000", snapshot["committed_usd"]
    assert_equal "0.125000", snapshot["unknown_usd"]
    assert_equal "0.000000", snapshot["held_usd"]
    assert_equal "unknown", row["status"]
    assert_nil row["actual_usd"]
    assert_equal "0.125000", row["reserved_usd"]
  end

  test "an authorization survives another process and unknown still consumes it" do
    first = spend(call_cap: 152, cost_cap: "4")
    seed_history(140)
    grant = first.ensure_authorization!(id: "f2f3-joint-after-134", after_attempt: 134, cost_usd: "0.75", call_cap: 150)
    assert_equal 134, grant["after_attempt"]
    assert_equal 140, first.snapshot["entries"].size

    assert_raises(Rag::AssignmentSpend::Stop) do
      first.ensure_authorization!(id: "f2f3-joint-after-134", after_attempt: 134, cost_usd: "1.50", call_cap: 150)
    end
    same = Rag::AssignmentSpend.new(path: @path, call_cap: 152, cost_cap_usd: "4").ensure_authorization!(
      id: "f2f3-joint-after-134", after_attempt: 134, cost_usd: "0.75", call_cap: 150
    )
    assert_equal "0.750000", same["cost_usd"]

    execution = first.admit_execution!(
      id: "f3-vf5-20261023", cost_usd: "0.30", calls: 12,
      bump_call_cap_to: 152, bump_only_if_attempts: 140
    )
    assert_equal 140, execution["after_attempt"]
    assert_equal 152, first.snapshot["authorization"]["call_cap"]
    again = Rag::AssignmentSpend.new(path: @path, call_cap: 152, cost_cap_usd: "4").admit_execution!(
      id: "f3-vf5-20261023", cost_usd: "0.30", calls: 12,
      bump_call_cap_to: 152, bump_only_if_attempts: 0
    )
    assert_equal 140, again["after_attempt"]

    held = first.reserve!(ceiling_usd: "0.200000", model_id: "haiku", turn: 1)
    assert_raises(Rag::AssignmentSpend::Stop) do
      first.reserve!(ceiling_usd: "0.200000", model_id: "haiku", turn: 2)
    end
    assert first.unknown!(held, error_class: "timeout")
    restarted = Rag::AssignmentSpend.new(path: @path, call_cap: 152, cost_cap_usd: "4")
    assert_raises(Rag::AssignmentSpend::Stop) do
      restarted.reserve!(ceiling_usd: "0.200000", model_id: "haiku", turn: 3)
    end
    assert_equal 141, restarted.snapshot["attempts"]
    assert_equal 140, restarted.snapshot["entries"].count { |row| row["id"].to_i <= 140 }
  end

  test "a bump is refused when the ledger is no longer at the authorized attempt" do
    book = spend(call_cap: 152, cost_cap: "4")
    seed_history(141)
    book.ensure_authorization!(id: "f2f3-joint-after-134", after_attempt: 134, cost_usd: "0.75", call_cap: 150)
    book.admit_execution!(id: "later", cost_usd: "0.30", calls: 12, bump_call_cap_to: 152, bump_only_if_attempts: 140)
    assert_equal 150, book.snapshot["authorization"]["call_cap"]
  end

  test "a later execution is not blocked by an earlier grant that already used its calls" do
    book = spend(call_cap: 164, cost_cap: "4")
    seed_history(152)
    book.ensure_authorization!(id: "f2f3-joint-after-134", after_attempt: 134, cost_usd: "0.75", call_cap: 152)
    book.admit_execution!(id: "f3-vf5-20261023", cost_usd: "0.35", calls: 12)
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.010000", model_id: "haiku", turn: 1)
    end

    later = book.admit_execution!(
      id: "f3-q1-20261023", cost_usd: "0.75", calls: 12,
      bump_call_cap_to: 164, bump_only_if_attempts: 152
    )
    assert_equal 152, later["after_attempt"]
    assert_equal "0.750000", book.snapshot["authorization"]["cost_usd"]
    assert_equal 134, book.snapshot["authorization"]["after_attempt"]
    assert_equal 164, book.snapshot["authorization"]["call_cap"]
    assert book.reserve!(ceiling_usd: "0.010000", model_id: "haiku", turn: 1)
    assert_equal 153, book.snapshot["attempts"]
  end

  test "a scope continuation bumps 164 to 166 and does not renew the spent execution" do
    book = spend(call_cap: 166, cost_cap: "4")
    seed_history(164)
    book.ensure_authorization!(id: "f2f3-joint-after-134", after_attempt: 134, cost_usd: "0.75", call_cap: 164)
    book.admit_execution!(id: "f3-q1-20261023", cost_usd: "0.75", calls: 12)
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.admit_execution!(id: "f3-q1-20261023", cost_usd: "0.75", calls: 14)
    end

    later = book.admit_execution!(
      id: "f3-scope-reply-20261023", cost_usd: "0.10", calls: 2,
      bump_call_cap_to: 166, bump_only_if_attempts: 164
    )
    assert_equal 164, later["after_attempt"]
    assert_equal 2, later["calls"]
    assert_equal "0.750000", book.snapshot["authorization"]["cost_usd"]
    assert_equal 134, book.snapshot["authorization"]["after_attempt"]
    assert_equal "f2f3-joint-after-134", book.snapshot["authorization"]["id"]
    assert_equal 166, book.snapshot["authorization"]["call_cap"]
    assert_equal 12, book.snapshot["executions"].find { |row| row["id"] == "f3-q1-20261023" }["calls"]
    2.times { |index| book.reserve!(ceiling_usd: "0.010000", model_id: "haiku", turn: index + 1) }
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.010000", model_id: "haiku", turn: 3)
    end
    assert_equal 166, book.snapshot["attempts"]
    assert_equal "1.400000", book.snapshot["committed_usd"]
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

  def seed_history(attempts)
    entries = (1..attempts).map do |id|
      if id == 78
        { "id" => id, "status" => "unknown", "ceiling_usd" => "0.008617", "reserved_usd" => "0.008617" }
      elsif id >= 135
        { "id" => id, "status" => "settled", "ceiling_usd" => "0.020000", "actual_usd" => "0.007000" }
      else
        { "id" => id, "status" => "settled", "ceiling_usd" => "0.010000", "actual_usd" => "0.010000" }
      end
    end
    File.write(@path, JSON.generate(
      "call_cap" => 150, "cost_cap_usd" => "4.000000", "attempts" => attempts, "blocked" => 0,
      "priced" => attempts - 1, "seq" => attempts, "committed" => "1.400000", "unknown" => "0.008617",
      "open" => {}, "entries" => entries
    ))
  end
end
