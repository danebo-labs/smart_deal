# frozen_string_literal: true

require "test_helper"
require_relative "../../support/field_case_history_helper"

class FieldCases::CloseRaceTest < ActiveSupport::TestCase
  include FieldCaseHistoryHelper

  self.use_transactional_tests = false

  setup { enable_history! }

  teardown do
    disable_history!
    if @case_id
      FieldTurn.where(field_case_id: @case_id).delete_all
      FieldCase.where(id: @case_id).delete_all
    end
  end

  test "two candidates for one turn keep a single winner with its citations and revision" do
    FieldCases::CloseTurn.name
    kase = open_case
    @case_id = kase.id
    turn = admit(kase, message: "carrera", client_submission_id: "sub-race").turn
    token = turn.execution_token
    attempt = turn.attempt
    account_id = kase.account_id
    user_id = kase.user_id
    candidates = %w[A B].map do |marker|
      {
        "published_text" => marker,
        "citations" => [ { "page" => marker == "A" ? 1 : 2, "marker" => marker } ],
        "state" => { "marker" => marker },
        "checkpoint" => { "card" => marker }
      }
    end

    ready = Queue.new
    start = Queue.new
    errors = Queue.new
    results = []
    guard = Mutex.new
    threads = candidates.map do |candidate|
      Thread.new do
        FieldCase.connection_pool.with_connection do
          ready << true
          start.pop
          result = FieldCases::CloseTurn.call(
            account: Account.find(account_id),
            user: User.find(user_id),
            field_case_id: @case_id,
            turn_id: turn.id,
            attempt:,
            execution_token: token,
            expected_state_revision: 0,
            outcome: "completed",
            response: {
              "published_text" => candidate["published_text"],
              "citations" => candidate["citations"]
            },
            technical_state: candidate["state"],
            checkpoint: candidate["checkpoint"]
          )
          guard.synchronize { results << result }
        end
      rescue StandardError => error
        errors << error
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| assert thread.join(10), "close did not finish" }

    raised = []
    raised << errors.pop until errors.empty?
    assert_empty raised, raised.map { |error| "#{error.class}: #{error.message}" }.join("\n")
    assert_equal 1, results.count(&:ok?)
    assert_equal 1, results.count(&:lost?)
    FieldCase.connection.clear_query_cache
    stored = FieldTurn.find(turn.id)
    marker = stored.response["published_text"]
    assert_includes %w[A B], marker
    assert_equal marker, stored.response["citations"].first["marker"]
    assert_equal marker, stored.checkpoint["card"]
    assert_equal marker, FieldCase.find(@case_id).technical_state["marker"]
    assert_equal 1, FieldCase.find(@case_id).state_revision
    assert_equal 1, stored.result_state_revision
    assert_equal "completed", stored.status
    results.each do |result|
      assert_equal marker, result.turn.reload.response["published_text"]
      assert_equal 1, result.field_case.reload.state_revision
    end
  end
end
