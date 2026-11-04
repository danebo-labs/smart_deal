# frozen_string_literal: true

require "test_helper"

# Sentences the interpreter did not index. The captured rows are stored
# model output. The counterexamples are not.
class Rag::TurnExcerptTest < ActiveSupport::TestCase
  CALLS = JSON.parse(Rails.root.join("test/fixtures/quote_reply/vf5_t2_quote_calls.json").read).fetch("calls")

  test "the captured t2 turn keeps only the sentence the interpreter did not index" do
    episode = apply_capture("t2")

    assert_equal [ "Fue solo la primera apertura" ], episode.excerpts.pluck("text")
    assert_equal "turn_excerpt", episode.excerpts.first["source"]
    assert_equal "query:excerpt", episode.excerpts.first["cid"]
    turn = call("t2").fetch("turn")
    row = episode.excerpts.first
    assert_equal row["text"], turn[row["a"]...row["b"]]
    assert_not_includes episode.observations.pluck("text"), "Fue solo la primera apertura"
    assert_includes Rag::CompanionCaseFacts.build(episode).prompt_block,
      "Dicho por el técnico, sin indexar: «Fue solo la primera apertura»."
  end

  test "captured turns that were indexed produce no excerpt" do
    assert_empty apply_capture("led").excerpts
    assert_empty apply_capture("mixed").excerpts
    assert_empty apply_capture("code").excerpts
    assert_empty apply_capture("ac").excerpts
  end

  test "a negation or a reversed order is not covered by the other sentence" do
    negated = apply_result("La puerta no abrió.", observations: [ "La puerta abrió" ])
    reversed = apply_result("Abrió y luego cerró.", observations: [ "Cerró y luego abrió" ])

    assert_equal [ "La puerta no abrió" ], negated.excerpts.pluck("text")
    assert_equal [ "Abrió y luego cerró" ], reversed.excerpts.pluck("text")
    assert_not_includes negated.observations.pluck("text"), "La puerta no abrió"
  end

  test "only report follow_up answer_pending and correct keep excerpts, three per turn and eight per episode" do
    skipped = apply_result("La puerta no abrió.", observations: [], move: "new_work")
    assert_empty skipped.excerpts

    capped = apply_result("Uno. Dos. Tres. Cuatro.", observations: [])
    assert_equal [ "Uno", "Dos", "Tres" ], capped.excerpts.pluck("text")

    episode = Rag::ActiveEpisode.open(correlation_id: "query:excerpt", now: Time.current)
    episode.append_excerpts!(9.times.map { |index| row("Frase #{index}") })
    assert_equal 8, episode.excerpts.size
    assert_equal "Frase 1", episode.excerpts.first["text"]
    assert_equal "Frase 8", episode.excerpts.last["text"]

    stored = Rag::ActiveEpisode.parse(episode.to_h)
    assert_equal episode.excerpts, stored.excerpts
  end

  test "the interpreter sees at most three unindexed sentences of 180 characters" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:excerpt", now: Time.current)
    episode.append_excerpts!([
      row("Primera"),
      row("Segunda"),
      row("Tercera"),
      row("L" * 200)
    ])
    context = interpreter(episode).send(:work_context)

    assert_equal [ "Segunda", "Tercera", "L" * 180 ], context["unindexed"]
    assert_equal 180, context["unindexed"].last.length
  end

  test "an excerpt can ground reported order and cannot ground a prescription or an operation" do
    ordered = check_reading(
      "Después la puerta abre en la primera operación.",
      excerpts: [ row("después") ]
    )
    prescribed = check_reading(
      "La puerta debe abrir en la primera operación.",
      excerpts: [ row("debe abrir") ]
    )
    asked = check_question(
      "¿Puedo puentear el borne?",
      excerpts: [ row("puentear el borne") ]
    )
    grounded = check_question("¿La puerta abre en la primera operación transitoria?", excerpts: [ row("Fue transitoria") ])
    loose = check_question("¿La puerta abre en la primera operación transitoria?")

    assert_empty ordered.rejections.select { |item| item["reason"] == "order" }
    assert ordered.links.any?
    assert_equal "prescription", link_reason(prescribed)
    assert_equal "operation", question_reason(asked)
    assert_nil question_reason(grounded)
    assert_equal "ungrounded:transitoria", question_reason(loose)
  end

  private

  def call(id)
    CALLS.find { |row| row["id"] == id }
  end

  def apply_capture(id)
    row = call(id)
    episode = Rag::ActiveEpisode.open(correlation_id: "query:excerpt", now: Time.current)
    apply_turn(episode, row.fetch("raw"), row.fetch("turn"))
    episode
  end

  def apply_result(turn, observations:, move: "report")
    episode = Rag::ActiveEpisode.open(correlation_id: "query:excerpt", now: Time.current)
    perception = Rag::TurnPerception::Result.new(
      valid: true, move: move, observations: observations, identities: [],
      checks: [], part_replies: [], part_replies_given: false, part_replies_field: "absent"
    )
    settle(episode, perception, turn)
    episode
  end

  def apply_turn(episode, raw, turn)
    perception = Rag::TurnPerception.build(
      raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil
    )
    settle(episode, perception, turn)
  end

  def settle(episode, perception, turn)
    decision = Struct.new(:decision, :pending_question) do
      def performs_retrieval? = false
    end.new("retrieve", nil)
    Rag::WorkContextReducer.apply!(
      episode: episode, perception: perception, decision: decision,
      turn: turn, correlation_id: "query:excerpt", now: Time.current
    )
  end

  def interpreter(episode)
    Rag::TurnInterpreter.new(
      turn: "siguiente", episode: episode, viewer_account: nil,
      correlation_id: "query:excerpt", attribution: nil, client: Object.new, catalog: Object.new
    )
  end

  def row(text)
    { "text" => text, "cid" => "query:excerpt", "a" => 0, "b" => text.length, "source" => "turn_excerpt" }
  end

  def check_reading(reading, excerpts: [])
    statements = Rag::CompanionStatements.parse([ chunk ])
    facts = Rag::CompanionCaseFacts.build(valve_case(excerpts: excerpts))
    Rag::CompanionPlanCheck.call(
      { "links" => [ { "fact" => "O1", "statement" => statements.statements.first.id, "reading" => reading } ] },
      facts: facts, statements: statements, turns: []
    )
  end

  def check_question(question, excerpts: [])
    statements = Rag::CompanionStatements.parse([ chunk ])
    facts = Rag::CompanionCaseFacts.build(valve_case(excerpts: excerpts))
    Rag::CompanionPlanCheck.call(
      { "question" => question },
      facts: facts, statements: statements, turns: []
    )
  end

  def valve_case(excerpts: [])
    episode = Rag::ActiveEpisode.open(correlation_id: "query:excerpt", now: Time.current)
    episode.assign_goal!("diagnosticar la puerta", correlation_id: "query:excerpt")
    episode.append_observation!("La puerta abre en la primera operación.", correlation_id: "query:excerpt")
    episode.append_excerpts!(excerpts)
    episode
  end

  def chunk
    { content: "La puerta abre en la primera operación.", metadata: { "page_number" => "8" } }
  end

  def link_reason(result)
    result.rejections.find { |item| item["part"] == "link" }&.dig("reason")
  end

  def question_reason(result)
    result.rejections.find { |item| item["part"] == "question" }&.dig("reason")
  end
end
