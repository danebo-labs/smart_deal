# frozen_string_literal: true

require "test_helper"
require_relative "../../support/field_case_history_helper"

# A persisted case is reopened after the turn that published the check, and
# the turn that answered it, have fallen outside the last three field turns.
# CheckOutcome has to recover the published question exactly and tie it to
# that answer. The episode stores only the reply correlation.
#
# The reference is the reply correlation id: it names a completed FieldTurn
# of the same case. That turn holds the technician's words and the completed
# turn before it holds the published question. conversation_history stays at
# three turns. When the reference is not on the case, the stored state is
# kept and missing_references names the absent one.
class FieldCases::CheckOutcomeReopenTest < ActiveSupport::TestCase
  include FieldCaseHistoryHelper

  QUESTION = "¿La válvula 4 está abierta?"
  ANSWER = "La válvula queda abierta."
  LATER = "¿El indicador está encendido?"

  test "reopening past the last three turns keeps the original question on its reply" do
    kase, turns, context = reopen(published_first: "Revisa el circuito.\n\n#{QUESTION}")
    answered = turns[1]
    visible = context.conversation_history.select { |message| message["role"] == "user" }.pluck("correlation_id")

    assert_equal turns.last(3).map(&:correlation_id), visible
    assert_not_includes visible, turns.first.correlation_id
    assert_not_includes visible, answered.correlation_id
    assert_includes turns.first.response.fetch("published_text"), QUESTION
    assert_equal ANSWER, answered.message

    outcome = outcome_for(context, turns.last)
    row = outcome.closed.find { |item| item.reply_id == "r1" }

    assert row, outcome.closed.map(&:reply_id).inspect
    assert_equal QUESTION, row.question, outcome.lines.join("\n")
    assert_equal "r1", row.reply_id
    assert_equal answered.correlation_id, row.correlation_id
    assert_equal ANSWER, row.quote, outcome.lines.join("\n")
    assert_empty outcome.missing_references
    assert_equal kase.id, context.case_id
  end

  test "the reference is read once per correlation id and only for turns outside the window" do
    _kase, turns, context = reopen(published_first: "Revisa el circuito.\n\n#{QUESTION}")
    outcome = nil
    queries = field_turn_queries { outcome = outcome_for(context, turns.last) }

    assert_equal ANSWER, outcome.closed.find { |item| item.reply_id == "r1" }.quote
    assert_operator queries, :<=, 2
    assert_equal 0, field_turn_queries { outcome_for(context, turns.last).lines }
  end

  test "a published turn without a question keeps the stored state and names the missing question" do
    _kase, turns, context = reopen(published_first: "Revisa el circuito.")
    outcome = outcome_for(context, turns.last)
    row = outcome.closed.find { |item| item.reply_id == "r1" }

    assert_nil row.question
    assert_equal ANSWER, row.quote
    assert_equal "complete", row.state
    assert_includes outcome.lines.join("\n"), "- q1.p1: complete (r1) («#{ANSWER}»)."
    assert_equal [ { "reply_id" => "r1", "correlation_id" => turns[1].correlation_id, "reference" => "question_text" } ],
                 outcome.missing_references
    assert_equal outcome.to_trace["missing_references"], outcome.missing_references
  end

  test "a reply whose correlation is not a completed turn of the case names both missing references" do
    _kase, turns, context = reopen(published_first: "Revisa el circuito.\n\n#{QUESTION}", cid: "no-such-turn")
    outcome = outcome_for(context, turns.last)
    row = outcome.closed.find { |item| item.reply_id == "r1" }

    assert_nil row.question
    assert_nil row.quote
    assert_equal %w[question_text technician_text], outcome.missing_references.pluck("reference").sort
  end

  test "another case never supplies the reference" do
    _kase, turns, context = reopen(published_first: "Revisa el circuito.\n\n#{QUESTION}")
    other = open_case
    assert admit(other, message: "Otro caso.").ok?
    foreign = FieldCases::TurnContext.build(other.reload, focus: [])
    outcome = Rag::CheckOutcome.new(
      episode: Rag::ActiveEpisode.parse(context.active_episode), session: foreign, correlation_id: turns.last.correlation_id
    )
    row = outcome.closed.find { |item| item.reply_id == "r1" }

    assert_nil row.question
    assert_nil row.quote
  end

  test "the photo snapshot carries the case id" do
    _kase, _turns, context = reopen(published_first: "Revisa el circuito.\n\n#{QUESTION}")
    snapshot = FieldCases::TurnContext.instantiate(context.attributes)
    snapshot.copy_case_window_from(context)

    assert_equal context.case_id, snapshot.case_id
  end

  private

  def outcome_for(context, latest)
    Rag::CheckOutcome.new(
      episode: Rag::ActiveEpisode.parse(context.active_episode), session: context, correlation_id: latest.correlation_id
    )
  end

  def field_turn_queries
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      count += 1 if payload[:sql].match?(/FROM "field_turns"/) && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  def reopen(published_first:, cid: nil)
    kase = open_case
    published = [
      published_first,
      "Anotado.\n\n#{LATER}",
      "Sigo con el tercero.",
      "Sigo con el cuarto.",
      "Sigo con el quinto."
    ]
    messages = [
      "El conjunto no responde.",
      ANSWER,
      "El tercero no repite la válvula.",
      "El cuarto tampoco.",
      "El quinto cierra el caso."
    ]
    turns = messages.zip(published).map do |message, text|
      admission = admit(kase, message: message)
      assert admission.ok?, admission.error.inspect
      state = text == published.last ? episode_state(kase, admission.turn, cid: cid) : { "v" => 1 }
      closed = close_turn(kase, admission.turn, published_text: text, state: state, checkpoint: state)
      assert closed.ok?, closed.error.inspect
      admission.turn.reload
    end
    [ kase, turns, FieldCases::TurnContext.build(kase.reload, focus: []) ]
  end

  # The pending question is the later one. q1's wording is not on the episode.
  # r1 points at the turn that answered it.
  def episode_state(kase, latest, cid: nil)
    now = Time.current.iso8601
    {
      "v" => 1,
      "episode_id" => kase.episode_id,
      "status" => "active",
      "opened_at" => now,
      "updated_at" => now,
      "opened_by" => latest.correlation_id,
      "qc" => Rag::AnswerContract::VERSION,
      "id_seq" => { "q" => 2, "p" => 2, "r" => 1 },
      "pending_question" => {
        "id" => "q2",
        "type" => "documented_context",
        "question" => LATER,
        "targets" => [],
        "parts" => [ { "id" => "p2", "role" => "main", "text" => LATER } ]
      },
      "replies" => [
        {
          "id" => "r1", "q" => "q1", "p" => "p1", "state" => "complete",
          "cid" => cid || latest.field_case.field_turns.order(:sequence).second.correlation_id,
          "a" => 0, "b" => ANSWER.length
        }
      ]
    }
  end
end
