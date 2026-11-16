# frozen_string_literal: true

require "test_helper"

class Rag::ThyssenPhotoLiveGrantTest < ActiveSupport::TestCase
  PHOTO_CALLS = Rag::AssignmentSpend::THYSSEN_PHOTO_RUN_CALLS
  PHOTO_USD = Rag::AssignmentSpend::THYSSEN_PHOTO_RUN_USD

  setup do
    @dir = Dir.mktmpdir("thyssen-photo-grant")
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
    book.admit_kone_lwi_run!(calls: 7, cost_usd: "0.024921")
    settle_calls(7, "0.001000", Rag::AssignmentSpend::KONE_LWI_LIVE_ID)
  end

  teardown do
    @saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  test "the kone window does not admit the photo script until its own grant opens" do
    assert_equal "thyssen_photo_calls", Rag::AssignmentSpend.thyssen_photo_refusal(ledger, calls: 18, cost_usd: PHOTO_USD)
    assert_equal "thyssen_photo_usd", Rag::AssignmentSpend.thyssen_photo_refusal(ledger, calls: PHOTO_CALLS, cost_usd: "0.063917")
    assert_equal 0, Haiku55HttpGrant.room(ledger)["calls"]

    bare = ledger
    bare["executions"].reject! { |row| row["id"] == Rag::AssignmentSpend::KONE_LWI_LIVE_ID }
    bare["authorization"]["call_cap"] = 1250
    bare["call_cap"] = 1250
    assert_equal "thyssen_photo_ledger_baseline_changed",
      Rag::AssignmentSpend.thyssen_photo_refusal(bare, calls: PHOTO_CALLS, cost_usd: PHOTO_USD)

    row = book_for_ledger.admit_thyssen_photo_run!(calls: PHOTO_CALLS, cost_usd: PHOTO_USD)

    assert_equal Rag::AssignmentSpend::THYSSEN_PHOTO_LIVE_ID, row["id"]
    assert_equal PHOTO_CALLS, row["calls"]
    assert_equal PHOTO_USD, row["cost_usd"]
    assert_equal 1269, ledger.dig("authorization", "call_cap")
    assert_equal "4.0", ledger["cost_cap_usd"]
    assert_equal PHOTO_CALLS, Haiku55HttpGrant.room(ledger)["calls"]
    assert_equal PHOTO_USD, format("%.6f", Haiku55HttpGrant.room(ledger)["usd"])

    error = assert_raises(Rag::AssignmentSpend::Stop) do
      book_for_ledger.admit_thyssen_photo_run!(calls: PHOTO_CALLS, cost_usd: PHOTO_USD)
    end
    assert_equal "thyssen_photo_room_already_covers", error.message
    assert_equal 1, ledger.fetch("executions").count { |item| item["id"] == Rag::AssignmentSpend::THYSSEN_PHOTO_LIVE_ID }
  end

  test "seventeen calls settle inside the photo window and the next call stops" do
    book_for_ledger.admit_thyssen_photo_run!(calls: PHOTO_CALLS, cost_usd: PHOTO_USD)
    assert_equal 150, recognized_cap
    ENV["RAG_ASSIGNMENT_EXECUTION_ID"] = Rag::AssignmentSpend::THYSSEN_PHOTO_LIVE_ID
    assert_equal 1269, recognized_cap

    spender = book_for_ledger
    PHOTO_CALLS.times do |index|
      id = spender.reserve!(ceiling_usd: "0.003000", model_id: "claude-haiku-5-5-direct", turn: index + 1,
        required_execution: Rag::AssignmentSpend::THYSSEN_PHOTO_LIVE_ID)
      spender.settle!(id, actual_usd: "0.003000")
    end
    error = assert_raises(Rag::AssignmentSpend::Stop) do
      spender.reserve!(ceiling_usd: "0.003000", model_id: "claude-haiku-5-5-direct", turn: PHOTO_CALLS + 1,
        required_execution: Rag::AssignmentSpend::THYSSEN_PHOTO_LIVE_ID)
    end
    assert_equal "assignment_spend", error.message
    assert_equal 1252 + PHOTO_CALLS, spender.snapshot["attempts"]
    assert_equal "4.0", ledger["cost_cap_usd"]
  end

  test "twenty photo runs reach the ceiling and the next run is refused" do
    20.times do
      current = book_for_ledger
      current.admit_thyssen_photo_run!(calls: PHOTO_CALLS, cost_usd: PHOTO_USD)
      settle_calls(PHOTO_CALLS, "0.001000", Rag::AssignmentSpend::THYSSEN_PHOTO_LIVE_ID)
    end

    grants = ledger.fetch("executions").select { |row| row["id"] == Rag::AssignmentSpend::THYSSEN_PHOTO_LIVE_ID }
    assert_equal Rag::AssignmentSpend::THYSSEN_PHOTO_MAX_CALLS, grants.sum { |row| row["calls"] }
    assert_equal BigDecimal(Rag::AssignmentSpend::THYSSEN_PHOTO_MAX_USD),
      grants.sum(BigDecimal("0")) { |row| BigDecimal(row["cost_usd"]) }
    assert_equal "4.0", ledger["cost_cap_usd"]

    error = assert_raises(Rag::AssignmentSpend::Stop) do
      book_for_ledger.admit_thyssen_photo_run!(calls: PHOTO_CALLS, cost_usd: PHOTO_USD)
    end
    assert_equal "thyssen_photo_call_ceiling", error.message
  end

  test "a photo window the assignment cap cannot pay is refused" do
    state = ledger
    state["committed"] = "3.950000"
    state["unknown"] = "0.000000"
    state["open"] = {}
    File.write(@path, JSON.generate(state))

    error = assert_raises(Rag::AssignmentSpend::Stop) do
      book_for_ledger.admit_thyssen_photo_run!(calls: PHOTO_CALLS, cost_usd: PHOTO_USD)
    end
    assert_equal "thyssen_photo_assignment_budget", error.message
    assert_equal 1252, ledger.dig("authorization", "call_cap")
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

  def settle_calls(count, amount, execution)
    spender = book_for_ledger
    count.times do |index|
      id = spender.reserve!(ceiling_usd: amount, model_id: "claude-haiku-5-5-direct", turn: index + 1,
        required_execution: execution)
      spender.settle!(id, actual_usd: amount)
    end
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
