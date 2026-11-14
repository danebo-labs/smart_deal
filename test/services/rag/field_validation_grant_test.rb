# frozen_string_literal: true

require "test_helper"

class Rag::FieldValidationGrantTest < ActiveSupport::TestCase
  INTERPRETER = BigDecimal("0.001524")
  GENERATION = BigDecimal("0.006124")

  setup do
    @dir = Dir.mktmpdir("field-grant")
    @path = File.join(@dir, "spend.json")
    @saved = {
      "VF5_ASSIGNMENT_SPEND" => ENV["VF5_ASSIGNMENT_SPEND"],
      "RAG_ASSIGNMENT_SPEND_PATH" => ENV["RAG_ASSIGNMENT_SPEND_PATH"]
    }
    ENV["VF5_ASSIGNMENT_SPEND"] = @path
  end

  teardown do
    @saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  test "runner prices sum to the acceptance and regression grants" do
    http
    turn = Haiku55Companion.per_turn_ceiling

    assert_equal INTERPRETER, turn["interpreter"]
    # The historical grant amounts below remain fixed. The integrated system
    # prompt adds to the ceiling for current requests.
    assert_equal BigDecimal("0.006267"), turn["generation"]
    assert_equal 10, acceptance_amounts.size
    assert_equal BigDecimal("0.033640"), acceptance_amounts.sum(BigDecimal("0"))
    assert_equal 37, regression_amounts.size
    assert_equal BigDecimal("0.129988"), regression_amounts.sum(BigDecimal("0"))
  end

  test "an unrecognized ten-call row still charges the tenth price to the CEA window" do
    write_observed
    book, = server
    book.admit_execution!(id: "not-a-field-grant", cost_usd: "0.033640", calls: 10, start_after_sequence: true)
    assert_equal 1145, JSON.parse(File.read(@path)).fetch("executions").last["after_attempt"]
    assert_equal 1143, book.snapshot["attempts"]

    fill(book, acceptance_amounts.first(9))
    refuse(book, acceptance_amounts.fetch(9))
    assert_equal 1152, book.snapshot["attempts"]
  end

  test "the acceptance grant cuts at sequence 1145 and rejects one price past its quota" do
    write_observed
    book, recognized = server
    assert_equal 1158, recognized
    row = book.admit_execution!(
      id: Rag::AssignmentSpend::FIELD_ACCEPTANCE_ID, cost_usd: "0.033640", calls: 10, start_after_sequence: true
    )

    assert_equal 1145, row["after_attempt"]
    assert_equal 1143, book.snapshot["attempts"]
    book.send(:with_lock) do |state, _file|
      assert_equal 0, book.send(:scoped_between, state, 1145, nil)
      assert_equal 8, book.send(:scoped_between, state, 1137, 1145)
    end
    fill(book, acceptance_amounts)
    refuse(book, INTERPRETER)

    state = JSON.parse(File.read(@path))
    assert_equal 1153, book.snapshot["attempts"]
    assert_equal 1155, state["seq"]
    assert_equal 1158, state.dig("authorization", "call_cap")
    assert_equal "4.0", state["cost_cap_usd"]
  end

  test "a matching id with a different dollar amount is not the acceptance window" do
    write_observed
    book, = server
    book.admit_execution!(
      id: Rag::AssignmentSpend::FIELD_ACCEPTANCE_ID, cost_usd: "0.033641", calls: 10, start_after_sequence: true
    )

    fill(book, acceptance_amounts.first(9))
    refuse(book, acceptance_amounts.fetch(9))
  end

  test "the global four dollar cap rejects a price the new grant would allow" do
    write_observed
    book, = server
    book.admit_execution!(
      id: Rag::AssignmentSpend::FIELD_ACCEPTANCE_ID, cost_usd: "0.033640", calls: 10, start_after_sequence: true
    )
    state = JSON.parse(File.read(@path))
    state["committed"] = "3.999000"
    state["unknown"] = "0.000000"
    state["open"] = {}
    File.write(@path, JSON.generate(state))
    capped, = server

    refuse(capped, INTERPRETER)
    assert_equal 1143, capped.snapshot["attempts"]
    assert_equal "4.0", JSON.parse(File.read(@path)).fetch("cost_cap_usd")
  end

  test "regression exhausts thirty-seven prices under 1190 and the next price stops" do
    write_observed
    book, = server
    book.admit_execution!(
      id: Rag::AssignmentSpend::FIELD_ACCEPTANCE_ID, cost_usd: "0.033640", calls: 10, start_after_sequence: true
    )
    row = book.admit_execution!(
      id: Rag::AssignmentSpend::FIELD_REGRESSION_ID, cost_usd: "0.129988", calls: 37,
      bump_call_cap_to: 1190, bump_only_if_attempts: 1143, start_after_sequence: true
    )

    assert_equal 1145, row["after_attempt"]
    assert_equal 1190, JSON.parse(File.read(@path)).dig("authorization", "call_cap")
    bumped, recognized = server
    assert_equal 1190, recognized
    fill(bumped, regression_amounts)
    refuse(bumped, INTERPRETER)

    assert_equal 1180, bumped.snapshot["attempts"]
    bumped.send(:with_lock) do |state, _file|
      assert_equal 37, bumped.send(:scoped_between, state, 1145, nil)
      assert_operator state["attempts"] + 1, :<=, bumped.send(:attempt_cap, state)
    end
  end

  test "ten acceptance calls plus thirty-seven regression calls stop at 1190 attempts" do
    write_observed(entries: (137..1145).map { |id| entry(id) })
    book, = server
    book.admit_execution!(
      id: Rag::AssignmentSpend::FIELD_ACCEPTANCE_ID, cost_usd: "0.033640", calls: 10, start_after_sequence: true
    )
    fill(book, Array.new(10, BigDecimal("0.001")))
    refuse(book, BigDecimal("0.001"))
    assert_equal 1153, book.snapshot["attempts"]

    book.admit_execution!(
      id: Rag::AssignmentSpend::FIELD_REGRESSION_ID, cost_usd: "0.129988", calls: 37,
      bump_call_cap_to: 1190, bump_only_if_attempts: 1153, start_after_sequence: true
    )
    bumped, recognized = server
    assert_equal 1190, recognized
    fill(bumped, Array.new(37, BigDecimal("0.001")))
    refuse(bumped, BigDecimal("0.001"))

    assert_equal 1190, bumped.snapshot["attempts"]
    assert_equal 1190, JSON.parse(File.read(@path)).dig("authorization", "call_cap")
  end

  test "1158 admits only fifteen new calls when 1009 entries already sit above attempt 134" do
    write_observed(entries: (137..1145).map { |id| entry(id) })
    book, = server
    book.admit_execution!(
      id: Rag::AssignmentSpend::FIELD_REGRESSION_ID, cost_usd: "0.129988", calls: 37, start_after_sequence: true
    )

    fill(book, Array.new(15, BigDecimal("0.001")))
    refuse(book, BigDecimal("0.001"))
    assert_equal 1158, book.snapshot["attempts"]
    assert_equal 1158, JSON.parse(File.read(@path)).dig("authorization", "call_cap")
  end

  test "1191 is not a recognized cap and falls back to 150" do
    write_observed
    state = JSON.parse(File.read(@path))
    state["call_cap"] = 1191
    state["authorization"]["call_cap"] = 1191
    File.write(@path, JSON.generate(state))
    _book, recognized = server(call_cap: 150)

    assert_equal 150, recognized
    assert_includes Rag::LocalPassLedger::ASSIGNMENT_CALL_CAPS, 1190
    assert_not_includes Rag::LocalPassLedger::ASSIGNMENT_CALL_CAPS, 1191
    assert_equal 1190, Rag::AssignmentSpend::CALL_CAP_BUMPS[1158]
  end

  test "the runner preflight and the admit path share each block's grant" do
    write_observed
    http
    before = Haiku55Http.grant_room(JSON.parse(File.read(@path)), phase: "acceptance")
    assert_equal Rag::AssignmentSpend::FIELD_ACCEPTANCE_ID, before["execution_id"]
    assert_equal 1145, before["after_attempt"]
    assert_equal 10, before["calls"]
    assert_equal "0.033640", format("%.6f", before["usd"])
    assert_equal 1158, before["next_cap"]

    assert Haiku55Http.admit_field_grant!(StringIO.new, "acceptance")
    after = Haiku55Http.grant_room(JSON.parse(File.read(@path)), phase: "acceptance")
    assert_equal before["calls"], after["calls"]
    assert_equal format("%.6f", before["usd"]), format("%.6f", after["usd"])
    assert_equal 1145, after["after_attempt"]
    assert_equal 1158, JSON.parse(File.read(@path)).dig("authorization", "call_cap")

    regression = Haiku55Http.grant_room(JSON.parse(File.read(@path)), phase: "regression")
    assert_equal Rag::AssignmentSpend::FIELD_REGRESSION_ID, regression["execution_id"]
    assert_equal 37, regression["calls"]
    assert_equal "0.129988", format("%.6f", regression["usd"])
    assert_equal 1190, regression["next_cap"]

    assert Haiku55Http.admit_field_grant!(StringIO.new, "regression")
    state = JSON.parse(File.read(@path))
    assert_equal 1190, state.dig("authorization", "call_cap")
    assert_equal 1145, state.fetch("executions").last["after_attempt"]
    assert_equal 37, Haiku55Http.grant_room(state, phase: "regression")["calls"]
    assert_equal "0.129988", format("%.6f", Haiku55Http.grant_room(state, phase: "regression")["usd"])
  end

  test "acceptance refuses a ledger that has moved off 1143 attempts or sequence 1145" do
    write_observed
    state = JSON.parse(File.read(@path))
    state["attempts"] = 1144
    File.write(@path, JSON.generate(state))
    http

    assert_not Haiku55Http.admit_field_grant!(StringIO.new, "acceptance")
    assert_nil JSON.parse(File.read(@path)).fetch("executions").find { |row|
      row["id"] == Rag::AssignmentSpend::FIELD_ACCEPTANCE_ID
    }
    assert_equal 1158, JSON.parse(File.read(@path)).dig("authorization", "call_cap")
  end

  private

  def http
    return Haiku55Http if defined?(Haiku55Http)

    ENV["HTTP55_REQUIRE"] = "1"
    ENV["OPUS55_REQUIRE"] = "1"
    ENV.delete("HTTP55_EXECUTE")
    ENV.delete("OPUS55_EXECUTE")
    load Rails.root.join("script/field_companion/run_haiku55_http.rb")
    Haiku55Http
  end

  def server(call_cap: nil)
    ENV["RAG_ASSIGNMENT_SPEND_PATH"] = @path
    recognized = Rag::LocalPassLedger.send(:assignment_call_cap)
    book = Rag::AssignmentSpend.new(
      path: @path, call_cap: call_cap || recognized,
      cost_cap_usd: Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD
    )
    [ book, recognized ]
  end

  def fill(book, amounts)
    amounts.each_with_index do |amount, index|
      book.reserve!(ceiling_usd: amount, model_id: "claude-haiku-5-5-direct", turn: index + 1)
    end
  end

  def refuse(book, amount)
    before = book.snapshot["attempts"]
    error = assert_raises(Rag::AssignmentSpend::Stop) do
      book.reserve!(ceiling_usd: amount, model_id: "claude-haiku-5-5-direct", turn: "over")
    end
    assert_equal "assignment_spend", error.message
    assert_equal before, book.snapshot["attempts"]
  end

  def acceptance_amounts
    script_amounts(1) + script_amounts(3)
  end

  def regression_amounts
    [ 3, 5, 4, 2, 2 ].flat_map { |turns| script_amounts(turns) }
  end

  def script_amounts(turns)
    amounts = []
    turns.times { amounts << INTERPRETER << GENERATION }
    amounts << INTERPRETER
  end

  def write_observed(entries: nil)
    rows = entries || ((1124..1136).map { |id| entry(id) } + [ entry(1137, "0.014129") ] +
      (1138..1144).map { |id| entry(id) } + [ entry(1145, "0.008781") ])
    File.write(@path, JSON.generate(
      "call_cap" => 1158, "cost_cap_usd" => "4.0", "attempts" => 1143, "blocked" => 0,
      "priced" => 1113, "seq" => 1145, "committed" => "3.184261", "unknown" => "0.383074",
      "open" => { "329" => "0.001159" },
      "authorization" => { "id" => "f2f3-joint-after-134", "after_attempt" => 134, "cost_usd" => "0.750000", "call_cap" => 1158 },
      "executions" => [
        { "id" => "haiku55-http-cea-completion-20261112", "after_attempt" => 1123, "cost_usd" => "0.055060", "calls" => 15 },
        { "id" => Rag::AssignmentSpend::FIELD_ACCEPTANCE_PREVIOUS_ID, "after_attempt" => 1137, "cost_usd" => "0.033640", "calls" => 10 }
      ],
      "entries" => rows
    ))
  end

  def entry(id, actual = "0.000000")
    { "id" => id, "status" => "settled", "actual_usd" => actual }
  end
end
