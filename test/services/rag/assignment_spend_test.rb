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

  test "an apertura continuation bumps 166 to 174 and keeps the dollar cap and history" do
    seed_history(166)
    data = JSON.parse(File.read(@path))
    data["call_cap"] = 166
    data["authorization"] = {
      "id" => "f2f3-joint-after-134", "after_attempt" => 134,
      "cost_usd" => "0.750000", "call_cap" => 166
    }
    data["executions"] = [ {
      "id" => "f3-scope-reply-20261023", "after_attempt" => 164,
      "cost_usd" => "0.100000", "calls" => 2, "at" => "2026-10-24T00:10:46Z"
    } ]
    File.write(@path, JSON.generate(data))
    book = spend(call_cap: 174, cost_cap: "4")
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.010000", model_id: "haiku", turn: 1)
    end
    assert_equal 166, book.snapshot["attempts"]
    history = book.snapshot["entries"]

    later = book.admit_execution!(
      id: "vf5-apertura-lenta-20261103", cost_usd: "0.440000", calls: 8,
      bump_call_cap_to: 174, bump_only_if_attempts: 166
    )
    snap = book.snapshot

    assert_equal 166, later["after_attempt"]
    assert_equal 8, later["calls"]
    assert_equal "0.440000", later["cost_usd"]
    assert_equal 174, snap["authorization"]["call_cap"]
    assert_equal "0.750000", snap["authorization"]["cost_usd"]
    assert_equal 134, snap["authorization"]["after_attempt"]
    assert_equal "f2f3-joint-after-134", snap["authorization"]["id"]
    assert_equal "4.0", snap["cost_cap_usd"]
    assert_equal history, snap["entries"]
    assert_equal 2, snap["executions"].find { |row| row["id"] == "f3-scope-reply-20261023" }["calls"]
    assert_equal 175, Rag::AssignmentSpend::CALL_CAP_BUMPS[174]
    assert_equal 180, Rag::AssignmentSpend::CALL_CAP_BUMPS[175]
    assert_nil Rag::AssignmentSpend::CALL_CAP_BUMPS[180]

    8.times { |index| assert book.reserve!(ceiling_usd: "0.010000", model_id: "haiku", turn: index + 1) }
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.010000", model_id: "haiku", turn: 9)
    end
    finished = book.snapshot
    assert_equal 174, finished["attempts"]
    assert_equal 166, finished["entries"].count { |row| row["id"].to_i <= 166 }
    assert_equal "4.0", finished["cost_cap_usd"]
    assert_equal "0.750000", finished["authorization"]["cost_usd"]
  end

  test "a cap above 174 is not recorded when the ledger has left 166" do
    seed_history(167)
    data = JSON.parse(File.read(@path))
    data["authorization"] = {
      "id" => "f2f3-joint-after-134", "after_attempt" => 134,
      "cost_usd" => "0.750000", "call_cap" => 166
    }
    File.write(@path, JSON.generate(data))
    book = spend(call_cap: 174, cost_cap: "4")
    book.admit_execution!(
      id: "late", cost_usd: "0.100000", calls: 8,
      bump_call_cap_to: 175, bump_only_if_attempts: 166
    )

    assert_equal 166, book.snapshot["authorization"]["call_cap"]
    assert_equal "0.750000", book.snapshot["authorization"]["cost_usd"]
    assert_equal "4.0", book.snapshot["cost_cap_usd"]
    assert_equal 167, book.snapshot["entries"].size
  end

  test "an interpreter evaluation bumps 174 to 175 only while attempts are 170" do
    seed_history(170)
    data = JSON.parse(File.read(@path))
    data["call_cap"] = 174
    data["authorization"] = {
      "id" => "f2f3-joint-after-134", "after_attempt" => 134,
      "cost_usd" => "0.750000", "call_cap" => 174
    }
    data["executions"] = [ {
      "id" => "vf5-apertura-lenta-20261103", "after_attempt" => 166,
      "cost_usd" => "0.440000", "calls" => 8, "at" => "2026-11-03T20:14:14Z"
    } ]
    File.write(@path, JSON.generate(data))
    history = JSON.parse(File.read(@path))["entries"]
    book = spend(call_cap: 175, cost_cap: "4")
    missed = book.admit_execution!(
      id: "vf5-t2-interpreter-late", cost_usd: "0.060000", calls: 5,
      bump_call_cap_to: 175, bump_only_if_attempts: 171
    )

    assert_equal 170, missed["after_attempt"]
    assert_equal 174, book.snapshot.dig("authorization", "call_cap")
    assert_equal "0.750000", book.snapshot.dig("authorization", "cost_usd")

    granted = book.admit_execution!(
      id: "vf5-t2-interpreter-20261103", cost_usd: "0.060000", calls: 5,
      bump_call_cap_to: 175, bump_only_if_attempts: 170
    )
    snap = book.snapshot

    assert_equal 170, granted["after_attempt"]
    assert_equal 5, granted["calls"]
    assert_equal "0.060000", granted["cost_usd"]
    assert_equal 175, snap.dig("authorization", "call_cap")
    assert_equal "0.750000", snap.dig("authorization", "cost_usd")
    assert_equal 134, snap.dig("authorization", "after_attempt")
    assert_equal "f2f3-joint-after-134", snap.dig("authorization", "id")
    assert_equal "4.0", snap["cost_cap_usd"]
    assert_equal history, snap["entries"]
    assert_equal 8, snap["executions"].find { |row| row["id"] == "vf5-apertura-lenta-20261103" }["calls"]

    5.times { |index| assert book.reserve!(ceiling_usd: "0.010000", model_id: "haiku", turn: index + 1) }
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.010000", model_id: "haiku", turn: 6)
    end
    finished = book.snapshot
    assert_equal 175, finished["attempts"]
    assert_equal 170, finished["entries"].count { |row| row["id"].to_i <= 170 }
    assert_equal "4.0", finished["cost_cap_usd"]
    assert_equal "0.750000", finished["authorization"]["cost_usd"]
  end

  test "a candidate evaluation bumps 175 to 180 only while attempts are 175" do
    seed_history(175)
    data = JSON.parse(File.read(@path))
    data["call_cap"] = 175
    data["authorization"] = {
      "id" => "f2f3-joint-after-134", "after_attempt" => 134,
      "cost_usd" => "0.750000", "call_cap" => 175
    }
    data["executions"] = [ {
      "id" => "vf5-t2-interpreter-20261103", "after_attempt" => 170,
      "cost_usd" => "0.060000", "calls" => 5, "at" => "2026-11-03T20:48:11Z"
    } ]
    File.write(@path, JSON.generate(data))
    history = JSON.parse(File.read(@path))["entries"]
    book = spend(call_cap: 180, cost_cap: "4")
    missed = book.admit_execution!(
      id: "vf5-t2-candidate-late", cost_usd: "0.070000", calls: 5,
      bump_call_cap_to: 180, bump_only_if_attempts: 176
    )

    assert_equal 175, missed["after_attempt"]
    assert_equal 175, book.snapshot.dig("authorization", "call_cap")
    assert_equal "0.750000", book.snapshot.dig("authorization", "cost_usd")

    granted = book.admit_execution!(
      id: "vf5-t2-candidate-20261103", cost_usd: "0.070000", calls: 5,
      bump_call_cap_to: 180, bump_only_if_attempts: 175
    )
    snap = book.snapshot

    assert_equal 175, granted["after_attempt"]
    assert_equal 5, granted["calls"]
    assert_equal "0.070000", granted["cost_usd"]
    assert_equal 180, snap.dig("authorization", "call_cap")
    assert_equal "0.750000", snap.dig("authorization", "cost_usd")
    assert_equal 134, snap.dig("authorization", "after_attempt")
    assert_equal "f2f3-joint-after-134", snap.dig("authorization", "id")
    assert_equal "4.0", snap["cost_cap_usd"]
    assert_equal history, snap["entries"]
    assert_equal 5, snap["executions"].find { |row| row["id"] == "vf5-t2-interpreter-20261103" }["calls"]

    5.times { |index| assert book.reserve!(ceiling_usd: "0.014000", model_id: "haiku", turn: index + 1) }
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.014000", model_id: "haiku", turn: 6)
    end
    finished = book.snapshot
    assert_equal 180, finished["attempts"]
    assert_equal 175, finished["entries"].count { |row| row["id"].to_i <= 175 }
    assert_equal "4.0", finished["cost_cap_usd"]
    assert_equal "0.750000", finished["authorization"]["cost_usd"]
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
