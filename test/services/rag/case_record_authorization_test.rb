# frozen_string_literal: true

require "test_helper"

class Rag::CaseRecordAuthorizationTest < ActiveSupport::TestCase
  setup do
    @path = File.join(Dir.mktmpdir, "assignment_spend.json")
  end

  test "the case-record step is 213 to 229 and the ledger accepts that cap" do
    assert_equal 229, Rag::AssignmentSpend::CALL_CAP_BUMPS[213]
    assert_includes Rag::LocalPassLedger::ASSIGNMENT_CALL_CAPS, 229
    assert_equal 213, Rag::AssignmentSpend::CALL_CAP_BUMPS[211]
  end

  test "haiku 5.5 global reserves the short-context rate" do
    price = Rag::LocalPassLedger.price("global.anthropic.claude-haiku-5-5", 1_000, 1_000)

    assert_equal BigDecimal("0.0006"), price
  end

  test "sixteen calls can be reserved after the historical 213 attempts" do
    entries = (135..213).map { |id|
      { "id" => id, "status" => "settled", "ceiling_usd" => "0.001000", "actual_usd" => "0.001000" }
    }
    File.write(@path, JSON.generate(
      "attempts" => 213, "seq" => 215, "call_cap" => 213, "blocked" => 0, "priced" => 79,
      "committed" => "0.079000", "unknown" => "0.000000", "open" => {},
      "entries" => entries, "executions" => [],
      "cost_cap_usd" => "4.0",
      "authorization" => {
        "id" => "f2f3-joint-after-134", "after_attempt" => 134,
        "cost_usd" => "0.750000", "call_cap" => 213
      }
    ))
    book = Rag::AssignmentSpend.new(path: @path, call_cap: 229, cost_cap_usd: "4")
    granted = book.admit_execution!(
      id: "case-record-pasada1-20261107", cost_usd: "0.213505", calls: 16,
      bump_call_cap_to: 229, bump_only_if_attempts: 213
    )

    assert_equal 213, granted["after_attempt"]
    assert_equal 16, granted["calls"]
    assert_equal "f2f3-joint-after-134", book.snapshot.dig("authorization", "id")
    assert_equal "0.750000", book.snapshot.dig("authorization", "cost_usd")
    assert_equal 229, book.snapshot.dig("authorization", "call_cap")
    16.times { |index| assert book.reserve!(ceiling_usd: "0.001000", model_id: "global.anthropic.claude-haiku-5-5", turn: index + 1) }
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.001000", model_id: "global.anthropic.claude-haiku-5-5", turn: 17)
    end
  end

  test "the sonnet step is 229 to 245 and the ledger accepts that cap" do
    assert_equal 245, Rag::AssignmentSpend::CALL_CAP_BUMPS[229]
    assert_equal 229, Rag::AssignmentSpend::CALL_CAP_BUMPS[213]
    assert_includes Rag::LocalPassLedger::ASSIGNMENT_CALL_CAPS, 245
    assert_equal({ "cost_usd" => "1.170000", "calls" => 18 }, Rag::AssignmentSpend::DOLLAR_SUCCESSORS[229])
  end

  test "a mismatched sonnet cost does not open the new dollar window" do
    write_sonnet_file
    book = Rag::AssignmentSpend.new(path: @path, call_cap: 245, cost_cap_usd: "4")
    book.admit_execution!(
      id: "case-record-sonnet45-wrong", cost_usd: "1.170000", calls: 16,
      bump_call_cap_to: 245, bump_only_if_attempts: 229
    )

    assert_equal 245, book.snapshot.dig("authorization", "call_cap")
    assert_equal "0.750000", book.snapshot.dig("authorization", "cost_usd")
    error = assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.200000", model_id: "global.anthropic.claude-sonnet-4-5-20250929-v1:0", turn: 1)
    end
    assert_equal "assignment_spend", error.message
    assert_equal 229, book.snapshot["attempts"]
  end

  test "the sonnet grant keeps the historical dollar cap and allows sixteen new calls" do
    write_sonnet_file
    before = JSON.parse(File.read(@path))["entries"]
    book = Rag::AssignmentSpend.new(path: @path, call_cap: 245, cost_cap_usd: "4")
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.001000", model_id: "global.anthropic.claude-sonnet-4-5-20250929-v1:0", turn: 0)
    end

    granted = book.admit_execution!(
      id: "case-record-sonnet45-20261107", cost_usd: "1.170000", calls: 18,
      bump_call_cap_to: 245, bump_only_if_attempts: 229
    )
    snap = book.snapshot

    assert_equal 229, granted["after_attempt"]
    assert_equal 18, granted["calls"]
    assert_equal "1.170000", granted["cost_usd"]
    assert_equal "f2f3-joint-after-134", snap.dig("authorization", "id")
    assert_equal 134, snap.dig("authorization", "after_attempt")
    assert_equal "0.750000", snap.dig("authorization", "cost_usd")
    assert_equal 245, snap.dig("authorization", "call_cap")
    assert_equal before, snap["entries"]

    16.times do |index|
      assert book.reserve!(ceiling_usd: "0.001000", model_id: "global.anthropic.claude-sonnet-4-5-20250929-v1:0", turn: index + 1)
    end
    assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: "0.001000", model_id: "global.anthropic.claude-sonnet-4-5-20250929-v1:0", turn: 17)
    end
    assert_equal 245, book.snapshot["attempts"]
    assert_equal "0.750000", book.snapshot.dig("authorization", "cost_usd")
    assert_equal "0.740000", book.snapshot["entries"].find { |row| row["id"] == 200 }["actual_usd"]
  end

  private

  def write_sonnet_file
    File.write(@path, JSON.generate(
      "attempts" => 229, "seq" => 231, "call_cap" => 229, "blocked" => 0, "priced" => 1,
      "committed" => "0.740000", "unknown" => "0.003927", "open" => {},
      "entries" => [
        { "id" => 200, "status" => "settled", "ceiling_usd" => "0.740000", "actual_usd" => "0.740000" },
        { "id" => 230, "status" => "settled", "ceiling_usd" => "0.010000", "actual_usd" => "0.010000" },
        { "id" => 231, "status" => "unknown", "ceiling_usd" => "0.003927", "reserved_usd" => "0.003927" }
      ],
      "executions" => [],
      "cost_cap_usd" => "4.0",
      "authorization" => {
        "id" => "f2f3-joint-after-134", "after_attempt" => 134,
        "cost_usd" => "0.750000", "call_cap" => 229
      }
    ))
  end
end
