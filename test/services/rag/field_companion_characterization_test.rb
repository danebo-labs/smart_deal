# frozen_string_literal: true

require "test_helper"
require "yaml"

class Rag::FieldCompanionCharacterizationTest < ActiveSupport::TestCase
  CASES_PATH = Rails.root.join("test/fixtures/files/field_companion/cases.yml")
  NOW = Time.zone.parse("2026-09-23T14:00:00-03:00")
  ANNEX_IDS = %w[
    T-A T-B T-C T-D T-E T-F T-G T-H
    X-1 X-2 X-3 X-4 X-5 X-6 X-7 X-8 X-9 X-10 X-11 X-12 X-13 X-14 X-15
    P1 P2 P3 P4 P5
  ].freeze
  SPRING = "Cómo se ajustan los resortes de la fijación de cables ?"
  ELEMONT = "Elemont MH con placa CEA15, falla en puerta 1: el imán no magnetiza. ¿Qué reviso?"

  # Last user turn, as FollowupQueryRewriter and EpisodeThreadResolver answer
  # today. The orchestrator text is the string execute_rag_query would pass
  # on: the joined thread when the menu flag is on and the rewriter did not
  # apply, otherwise the rewriter's question. Nil means the menu returns
  # before the orchestrator. Later phases that change a row declare it in
  # Anexo F.
  CURRENT = {
    "T-A" => {
      applied: false,
      reason: "ambiguous_history",
      outcome: :join,
      thread_reason: "joined",
      orchestrator_text: [ SPRING, "Fuji Yida", "el modelo no lo sé" ].join("\n")
    },
    "T-B" => {
      applied: false,
      reason: "not_identifier",
      outcome: :join,
      thread_reason: "joined",
      orchestrator_text: [ ELEMONT, "código 8" ].join("\n")
    },
    "T-C" => {
      applied: false,
      reason: "new_question",
      outcome: :pass,
      thread_reason: "not_followup_shape",
      orchestrator_text: "¿y el LED 7?"
    },
    "T-D" => {
      applied: false,
      reason: "ambiguous_history",
      outcome: :join,
      thread_reason: "joined",
      orchestrator_text: [ ELEMONT, "código 8", "sigue sin magnetizar" ].join("\n")
    },
    "T-E" => {
      applied: false,
      reason: "new_question",
      outcome: :pass,
      thread_reason: "not_followup_shape",
      orchestrator_text: "¿qué reviso primero?"
    },
    "T-F" => {
      applied: false,
      reason: "ambiguous_history",
      outcome: :join,
      thread_reason: "joined",
      orchestrator_text: [
        SPRING, "Fuji Yida", "el modelo no lo sé", "No, no es Fuji Yida. Es KONE"
      ].join("\n")
    },
    "T-G" => {
      applied: false,
      reason: "ambiguous_history",
      outcome: :join,
      thread_reason: "joined",
      orchestrator_text: [
        ELEMONT, "código 8", "Ahora estoy revisando un KONE que no nivela en planta 3"
      ].join("\n")
    },
    "T-H" => {
      applied: false,
      reason: "not_identifier",
      outcome: :join,
      thread_reason: "joined",
      orchestrator_text: [ ELEMONT, "no muestra ningún código" ].join("\n")
    }
  }.freeze

  test "cases.yml lists every Anexo C case" do
    assert_equal ANNEX_IDS, cases.keys
  end

  test "current behavior: T-A" do
    assert_current("T-A")
  end

  test "current behavior: T-B" do
    assert_current("T-B")
  end

  test "current behavior: T-C" do
    assert_current("T-C")
  end

  test "current behavior: T-D" do
    assert_current("T-D")
  end

  test "current behavior: T-E" do
    assert_current("T-E")
  end

  test "current behavior: T-F" do
    assert_current("T-F")
  end

  test "current behavior: T-G" do
    assert_current("T-G")
  end

  test "current behavior: T-H" do
    assert_current("T-H")
  end

  private

  def assert_current(case_id)
    assert_equal CURRENT.fetch(case_id), characterize(case_id)
  end

  def characterize(case_id)
    session, question, correlation_id = build_session(cases.fetch(case_id).fetch("turns"))
    followup = Rag::FollowupQueryRewriter.call(
      question: question,
      conversation_session: session,
      account: accounts(:legacy),
      correlation_id: correlation_id,
      now: NOW
    )
    thread = Rag::EpisodeThreadResolver.call(
      question: question,
      conversation_session: session,
      correlation_id: correlation_id,
      locale: :es,
      now: NOW
    )

    {
      applied: followup.applied,
      reason: followup.reason,
      outcome: thread.outcome,
      thread_reason: thread.reason,
      orchestrator_text: orchestrator_text(question, followup, thread)
    }
  end

  # Mirrors RagQueryConcern#execute_rag_query for a web text turn with no
  # pin. Does not call the orchestrator.
  def orchestrator_text(question, followup, thread)
    text = followup.applied ? followup.question : question
    return text unless menu_applies?(followup)

    case thread.outcome
    when :join then thread.composed
    when :menu then nil
    else text
    end
  end

  def menu_applies?(followup)
    Rag::ThreadMenuFlag.enabled? &&
      !followup.applied &&
      %w[no_session non_web_channel account_mismatch].exclude?(followup.reason)
  end

  def build_session(turns)
    base = NOW - turns.size.minutes
    history = turns.each_with_index.map { |turn, index| history_row(turn, index, base) }
    last = history.rindex { |row| row["role"] == "user" }
    session = ConversationSession.create!(
      identifier: "field-companion-#{SecureRandom.hex(6)}",
      channel: "web",
      account: accounts(:legacy),
      expires_at: 30.days.from_now,
      conversation_history: history
    )
    [ session, history[last]["content"], history[last]["correlation_id"] ]
  end

  def history_row(turn, index, base)
    {
      "role" => turn.fetch("role"),
      "content" => turn.fetch("content"),
      "ts" => (base + index.minutes).iso8601,
      "correlation_id" => "query:t#{index}"
    }
  end

  def cases
    @cases ||= YAML.safe_load_file(CASES_PATH).index_by { |row| row.fetch("id") }
  end
end
