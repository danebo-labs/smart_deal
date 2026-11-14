# frozen_string_literal: true

require "test_helper"

class Rag::KoneLwiLiveGrantTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("kone-lwi-grant")
    @path = File.join(@dir, "spend.json")
    @saved = {
      "VF5_ASSIGNMENT_SPEND" => ENV["VF5_ASSIGNMENT_SPEND"],
      "RAG_ASSIGNMENT_SPEND_PATH" => ENV["RAG_ASSIGNMENT_SPEND_PATH"],
      "RAG_ASSIGNMENT_EXECUTION_ID" => ENV["RAG_ASSIGNMENT_EXECUTION_ID"],
      "HTTP55_REQUIRE" => ENV["HTTP55_REQUIRE"]
    }
    ENV["VF5_ASSIGNMENT_SPEND"] = @path
    ENV["RAG_ASSIGNMENT_SPEND_PATH"] = @path
    write_anchor
  end

  teardown do
    @saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  test "the historical bump map and the four dollar cap stay in place" do
    assert_nil Rag::AssignmentSpend::CALL_CAP_BUMPS[1250]
    assert_equal 1190, Rag::AssignmentSpend::CALL_CAP_BUMPS[1158]
    assert_equal 1250, Rag::AssignmentSpend::FIELD_CONTINUATION_CAP
    assert_not_includes Rag::LocalPassLedger::ASSIGNMENT_CALL_CAPS, 1252

    error = assert_raises(Rag::AssignmentSpend::Stop) { book.admit_field_continuation! }
    assert_equal "field_continuation_ledger_baseline_changed", error.message
    assert_equal 1250, ledger.dig("authorization", "call_cap")
    assert_equal "4.0", ledger["cost_cap_usd"]
  end

  test "one short run raises the cap by two calls and opens a seven call window" do
    assert_equal 5, Haiku55HttpGrant.room(ledger)["calls"]
    refute Rag::AssignmentSpend.kone_lwi_step_admissible?(ledger, calls: 8, cost_usd: "0.024921")
    assert_equal "kone_lwi_calls", Rag::AssignmentSpend.kone_lwi_refusal(ledger, calls: 8, cost_usd: "0.024921")
    assert_equal "kone_lwi_usd", Rag::AssignmentSpend.kone_lwi_refusal(ledger, calls: 7, cost_usd: "0.024922")

    row = book.admit_kone_lwi_run!(calls: 7, cost_usd: "0.024921")

    assert_equal Rag::AssignmentSpend::KONE_LWI_LIVE_ID, row["id"]
    assert_equal 1247, row["after_attempt"]
    assert_equal 7, row["calls"]
    assert_equal "0.024921", row["cost_usd"]
    assert_equal 1252, ledger.dig("authorization", "call_cap")
    assert_equal "4.0", ledger["cost_cap_usd"]
    assert_equal 7, Haiku55HttpGrant.room(ledger)["calls"]
    assert_equal "0.024921", format("%.6f", Haiku55HttpGrant.room(ledger)["usd"])

    error = assert_raises(Rag::AssignmentSpend::Stop) { book.admit_kone_lwi_run!(calls: 7, cost_usd: "0.024921") }
    assert_equal "kone_lwi_room_already_covers", error.message
    assert_equal 1, ledger.fetch("executions").count { |item| item["id"] == Rag::AssignmentSpend::KONE_LWI_LIVE_ID }
  end

  test "the server accepts 1252 only for the kone execution and still stops on the eighth call" do
    book.admit_kone_lwi_run!(calls: 7, cost_usd: "0.024921")
    assert_equal 150, recognized_cap
    ENV["RAG_ASSIGNMENT_EXECUTION_ID"] = Rag::AssignmentSpend::KONE_LWI_LIVE_ID
    assert_equal 1252, recognized_cap

    capped = ledger
    capped["authorization"]["call_cap"] = 1316
    capped["call_cap"] = 1316
    File.write(@path, JSON.generate(capped))
    assert_equal 150, recognized_cap
    write_anchor
    book.admit_kone_lwi_run!(calls: 7, cost_usd: "0.024921")
    ENV["RAG_ASSIGNMENT_EXECUTION_ID"] = Rag::AssignmentSpend::KONE_LWI_LIVE_ID

    live = book_for_ledger
    error = assert_raises(Rag::AssignmentSpend::Stop) do
      live.reserve!(ceiling_usd: "0.001000", model_id: "claude-haiku-5-5-direct", turn: 1,
        required_execution: Rag::AssignmentSpend::FIELD_CONTINUATION_ID)
    end
    assert_equal "execution_not_admitted", error.message
    assert_equal 1245, live.snapshot["attempts"]

    7.times do |index|
      id = live.reserve!(ceiling_usd: "0.001000", model_id: "claude-haiku-5-5-direct", turn: index + 1,
        required_execution: Rag::AssignmentSpend::KONE_LWI_LIVE_ID)
      live.settle!(id, actual_usd: "0.001000")
    end
    error = assert_raises(Rag::AssignmentSpend::Stop) do
      live.reserve!(ceiling_usd: "0.001000", model_id: "claude-haiku-5-5-direct", turn: 8,
        required_execution: Rag::AssignmentSpend::KONE_LWI_LIVE_ID)
    end
    assert_equal "assignment_spend", error.message
    assert_equal 1252, live.snapshot["attempts"]
    assert_equal "4.0", ledger["cost_cap_usd"]
  end

  test "ten runs reach the authorized ceiling and the next run is refused" do
    10.times do |run|
      current = book_for_ledger
      current.admit_kone_lwi_run!(calls: 7, cost_usd: "0.024921")
      spender = book_for_ledger
      7.times do |index|
        id = spender.reserve!(ceiling_usd: "0.001000", model_id: "claude-haiku-5-5-direct", turn: index + 1,
          required_execution: Rag::AssignmentSpend::KONE_LWI_LIVE_ID)
        spender.settle!(id, actual_usd: "0.001000")
      end
      assert_equal 1245 + (run + 1) * 7, spender.snapshot["attempts"]
    end

    state = ledger
    grants = state.fetch("executions").select { |row| row["id"] == Rag::AssignmentSpend::KONE_LWI_LIVE_ID }
    assert_equal 70, grants.sum { |row| row["calls"] }
    assert_equal BigDecimal("0.249210"), grants.sum(BigDecimal("0")) { |row| BigDecimal(row["cost_usd"]) }
    assert_equal 1315, state.dig("authorization", "call_cap")
    assert_equal "4.0", state["cost_cap_usd"]

    error = assert_raises(Rag::AssignmentSpend::Stop) do
      book_for_ledger.admit_kone_lwi_run!(calls: 7, cost_usd: "0.024921")
    end
    assert_equal "kone_lwi_call_ceiling", error.message
    assert_equal 10, ledger.fetch("executions").count { |row| row["id"] == Rag::AssignmentSpend::KONE_LWI_LIVE_ID }
  end

  test "a window the assignment cap cannot pay is refused" do
    state = ledger
    state["committed"] = "3.990000"
    state["unknown"] = "0.000000"
    state["open"] = {}
    File.write(@path, JSON.generate(state))

    error = assert_raises(Rag::AssignmentSpend::Stop) { book.admit_kone_lwi_run!(calls: 7, cost_usd: "0.024921") }
    assert_equal "kone_lwi_assignment_budget", error.message
    assert_equal 1250, ledger.dig("authorization", "call_cap")
    assert_equal "4.0", ledger["cost_cap_usd"]
  end

  private

  def book
    Rag::AssignmentSpend.new(path: @path, call_cap: 1250, cost_cap_usd: "4.0")
  end

  def book_for_ledger
    Rag::AssignmentSpend.new(path: @path, call_cap: ledger.dig("authorization", "call_cap"), cost_cap_usd: "4.0")
  end

  def recognized_cap
    Rag::LocalPassLedger.send(:assignment_call_cap)
  end

  def ledger
    JSON.parse(File.read(@path))
  end

  def write_anchor
    released = [ 500, 800 ]
    entries = (1..1247).map do |id|
      status = released.include?(id) ? "released" : "settled"
      { "id" => id, "status" => status, "actual_usd" => "0.000000", "ceiling_usd" => "0.001000" }
    end
    File.write(@path, JSON.generate(
      "call_cap" => 1250, "cost_cap_usd" => "4.0", "attempts" => 1245, "blocked" => 0,
      "priced" => 1245, "seq" => 1247, "committed" => "1.000000", "unknown" => "0.000000", "open" => {},
      "authorization" => { "id" => "f2f3-joint-after-134", "after_attempt" => 134, "cost_usd" => "0.750000", "call_cap" => 1250 },
      "executions" => [
        { "id" => Rag::AssignmentSpend::FIELD_CONTINUATION_ID, "after_attempt" => Rag::AssignmentSpend::FIELD_CONTINUATION_SEQUENCE,
          "cost_usd" => Rag::AssignmentSpend::FIELD_CONTINUATION_USD, "calls" => Rag::AssignmentSpend::FIELD_CONTINUATION_CALLS }
      ],
      "entries" => entries
    ))
  end
end

module Haiku55HttpGrant
  def self.room(ledger)
    ENV["HTTP55_REQUIRE"] = "1"
    ENV["OPUS55_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/run_haiku55_http.rb") unless defined?(Haiku55Http)
    Haiku55Http.grant_room(ledger, phase: "field_continuation")
  end
end
