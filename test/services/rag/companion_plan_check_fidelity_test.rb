# frozen_string_literal: true

require "test_helper"

class Rag::CompanionPlanCheckFidelityTest < ActiveSupport::TestCase
  LAB = Rails.root.join("test/fixtures/companion_plan_check")
  SLOW_QUESTION = "¿La puerta abrió lentamente solo en esta primera vez después del corte, " \
                  "o sigue abriéndose lentamente ahora?"

  test "lab r1 turn 1 keeps the section 5.8 link and the slow-open question" do
    result, statements = replay_fixture("lab_r1_t1")
    link = result.links.find { |item| item[:fact] == "O1" && item[:statement] == "S3.8" }
    rendered = render_fixture("lab_r1_t1", result)

    assert result.usable?
    assert link
    assert_nil link[:reading]
    assert result.rejections.any? { |row| row["part"] == "reading" && row["reason"].start_with?("degraded:ungrounded:") }
    assert_equal SLOW_QUESTION, result.question
    assert_equal [ "abriendose" ], result.question_fidelity["residue"]
    assert_equal [ "S3.8" ], result.question_fidelity["about"]
    assert_equal "model", result.question_fidelity["declared_by"]
    assert_includes JSON.parse(LAB.join("lab_r1_t1.json").read)["chunks"].pluck("chunk_id"), "chunk_p8_1"
    literal = statements.find("S3.8").text.sub(/[.\s]+\z/, "")
    assert_includes literal, "lentamente"
    assert_includes rendered, literal
    assert_includes rendered, SLOW_QUESTION
    assert_not_includes rendered, "lectura de Danebo"
  end

  test "lab r1 turn 2 keeps the section 5.8 link without repeating the question" do
    result, statements = replay_fixture("lab_r1_t2")
    link = result.links.find { |item| item[:fact] == "O1" && item[:statement] == "S3.8" }

    assert result.usable?
    assert link
    assert_nil link[:reading]
    assert_nil result.question
    assert_nil result.question_fidelity
    assert_includes JSON.parse(LAB.join("lab_r1_t2.json").read)["chunks"].pluck("chunk_id"), "chunk_p8_1"
    assert_includes statements.find("S3.8").text, "lentamente"
  end

  test "session 198 does not publish the encendido question or the recuperar question" do
    first = replay_capture(corrected("e32425aa-3e59-48e5-b833-4870607980c4"))
    second = replay_capture(
      corrected("d84e8a77-e272-44f1-ae84-1c9646468f06"),
      turns: [ capture_turn(corrected("e32425aa-3e59-48e5-b833-4870607980c4")),
               capture_turn(corrected("d84e8a77-e272-44f1-ae84-1c9646468f06")) ]
    )

    assert_includes first.plan_question, "encendido"
    assert first.result.rejections.any? { |row| row["part"] == "question" && row["reason"].include?("encendido") }
    assert_not_equal first.plan_question, first.result.question
    assert_not_includes first.result.question.to_s, "encendido"

    assert_includes second.plan_question, "recuperar"
    assert second.result.rejections.any? { |row| row["part"] == "question" && row["reason"] == "ungrounded:recuperar" }
    assert_not_includes second.result.question.to_s, "recuperar"
  end

  test "gui turn 3 drops the documentacion dice link and turn 4 drops recorrido" do
    third = replay_capture(gui("ebacf496-163e-4c53-ac81-607b62d7e818"))
    fourth = replay_capture(gui("e1a8155a-7e39-4450-a8ec-8075b79b263d"))

    assert third.result.rejections.any? { |row|
      row["part"] == "link" && row["reason"] == "ungrounded:documentacion,dice"
    }
    assert third.result.links.none? { |link| link[:reading].to_s.match?(/documentaci[oó]n dice/i) }

    assert fourth.result.rejections.any? { |row| row["part"] == "question" && row["reason"] == "ungrounded:recorrido" }
    assert_not_includes fourth.result.question.to_s, "recorrido"
  end

  test "lab r2 degrades the comportamiento lento reading and still publishes the statement literal" do
    played = replay_capture(r2("ae1c94a5-e53a-4c91-9790-8cc5a16bf49c"))
    link = played.result.links.find { |item| item[:statement] == "S3.8" }
    rendered = Rag::CompanionPlanRender.call(played.result, facts: played.facts, statements: played.statements)

    assert link
    assert_nil link[:reading]
    assert played.result.rejections.any? { |row|
      row["part"] == "reading" && row["reason"] == "degraded:ungrounded:comportamiento,lento"
    }
    assert_includes rendered, played.statements.find("S3.8").text.sub(/[.\s]+\z/, "")
    assert_not_includes rendered, "comportamiento lento"
    assert_not_includes rendered, "lectura de Danebo"
  end

  test "a reading negation absent from the statement rejects the link" do
    result = check_reading("La puerta no abre.", observation: "La puerta abre.")

    assert_empty result.links
    assert_equal "negation_not_grounded", link_reason(result)
  end

  test "a reading condition absent from the statement rejects the link" do
    result = check_reading("Si la puerta abre entonces el paso está libre.", observation: "La puerta abre.")

    assert_empty result.links
    assert_equal "condition_not_grounded", link_reason(result)
  end

  test "a causal reading absent from the statement rejects the link" do
    result = check_reading("La puerta abre porque el paso está libre.", observation: "La puerta abre.")

    assert_empty result.links
    assert_equal "condition_not_grounded", link_reason(result)
  end

  test "a reading that imports another component rejects the link" do
    manual = <<~TEXT
      • Válvula.
      El piloto se enciende cuando la válvula está abierta.
    TEXT
    statements = Rag::CompanionStatements.parse([ chunk(manual) ])
    sentence = statements.statements.find { |item| item.text.include?("piloto") }
    episode = open_case("el piloto está encendido")
    episode.upsert_check!(
      { "subject" => "compuerta", "status" => "done", "result" => "no está abierta" },
      correlation_id: "query:t2"
    )
    facts = Rag::CompanionCaseFacts.build(episode)
    reading = "La compuerta no está abierta, pero el piloto está encendido."
    result = Rag::CompanionPlanCheck.call(
      { "links" => [ { "fact" => facts.facts.find { |item| item.kind == "done_check" }.id,
                       "statement" => sentence.id, "reading" => reading } ] },
      facts: facts, statements: statements, turns: []
    )

    assert_not_includes sentence.text, "compuerta"
    assert_includes reading, "compuerta"
    assert_empty result.links
    assert_equal "unbacked_component", link_reason(result)
  end

  test "a prescriptive reading stays rejected when only the technician said it" do
    result = check_reading(
      "La puerta debe repetir el autoajuste.",
      observation: "La puerta abre.",
      turns: [ "Debe repetir el autoajuste." ]
    )

    assert_empty result.links
    assert_equal "prescription", link_reason(result)
  end

  test "a chronological phrase that only the technician said can stay in the reading" do
    manual = "Las puertas se abrirán lentamente en la primera operación."
    statements = Rag::CompanionStatements.parse([ chunk(manual) ])
    sentence = statements.statements.first
    reading = "Después de un fallo de alimentación las puertas se abrirán lentamente en la primera operación."
    facts = Rag::CompanionCaseFacts.build(open_case("La puerta abrió."))
    result = Rag::CompanionPlanCheck.call(
      { "links" => [ { "fact" => "O1", "statement" => sentence.id, "reading" => reading } ] },
      facts: facts, statements: statements,
      turns: [ "Después de un fallo de alimentación." ]
    )

    assert_equal reading, result.links.first[:reading]
    assert result.rejections.none? { |row| row["reason"] == "order" }
  end

  test "a question that says puentear is an operation even when the technician said it" do
    result = check_question(
      "¿Se puede puentear el encoder?",
      observation: "La puerta abre.",
      turns: [ "Puedo puentear el encoder." ]
    )

    assert_nil result.question
    assert_equal "operation", question_reason(result)
  end

  test "a question designator absent from the sources stays ungrounded" do
    manual = "El display muestra el código de fallo."
    %w[S3 E4].each do |mark|
      result = check_question(
        "¿El display muestra #{mark}?",
        manual: manual,
        observation: "El display muestra el código."
      )

      assert_nil result.question
      assert_equal "ungrounded:#{mark.downcase}", question_reason(result)
    end
  end

  private

  Replay = Data.define(:result, :facts, :statements, :plan_question)

  def replay_fixture(name)
    played = play(JSON.parse(LAB.join("#{name}.json").read))
    [ played.result, played.statements ]
  end

  def render_fixture(name, result)
    played = play(JSON.parse(LAB.join("#{name}.json").read))
    Rag::CompanionPlanRender.call(result, facts: played.facts, statements: played.statements)
  end

  def replay_capture(dir, turns: nil)
    capture = JSON.parse(dir.join("capture.json").read)
    events = capture["events"]
    rows = events.find { |event| event["kind"] == "retrieval_results" && event["stage"] == "publication_gate" }["rows"]
    play(
      "turns" => turns || [ events.find { |event| event["kind"] == "user_message" }["original"] ],
      "plan" => events.find { |event| event["kind"] == "companion_plan" }["tool_input"],
      "episode_after" => events.find { |event| event["kind"] == "episode_delta" }["episode_after"],
      "chunks" => rows.map { |row|
        { "page" => row["page"].to_i, "content" => dir.join(row.dig("text", "path")).read }
      }
    )
  end

  def play(fixture)
    at = Time.zone.parse(fixture.dig("episode_after", "updated_at")) + 1.second
    played = nil
    travel_to(at) do
      facts = Rag::CompanionCaseFacts.build(fixture["episode_after"])
      statements = Rag::CompanionStatements.parse(fixture["chunks"].map { |row|
        { content: row["content"], metadata: { "page_number" => row["page"].to_s } }
      })
      result = Rag::CompanionPlanCheck.call(
        fixture["plan"], facts: facts, statements: statements, turns: fixture["turns"]
      )
      played = Replay.new(result, facts, statements, fixture.dig("plan", "question").to_s)
    end
    played
  end

  def capture_turn(dir)
    JSON.parse(dir.join("capture.json").read)["events"].find { |event| event["kind"] == "user_message" }["original"]
  end

  def corrected(id)
    Rails.root.join("tmp/field_companion/validation_captures/vf5-corrected-20261103T201414Z", id)
  end

  def gui(id)
    Rails.root.join(
      "tmp/vf5_citation_gui_20261029/2026-10-29_2026-10-29_danebo-legacy/validation_captures/web-danebo-legacy",
      id
    )
  end

  def r2(id)
    Rails.root.join("tmp/field_companion/validation_captures/lab-vf5-ev-control-r2-20261029T235220Z", id)
  end

  def check_reading(reading, observation:, turns: [], manual: "La puerta abre en la primera operación.")
    statements = Rag::CompanionStatements.parse([ chunk(manual) ])
    facts = Rag::CompanionCaseFacts.build(open_case(observation))
    Rag::CompanionPlanCheck.call(
      { "links" => [ { "fact" => "O1", "statement" => statements.statements.first.id, "reading" => reading } ] },
      facts: facts, statements: statements, turns: turns
    )
  end

  def check_question(question, observation:, turns: [], manual: "La puerta abre en la primera operación.")
    statements = Rag::CompanionStatements.parse([ chunk(manual) ])
    sentence = statements.statements.find { |item| item.kind == "text" }
    facts = Rag::CompanionCaseFacts.build(open_case(observation))
    Rag::CompanionPlanCheck.call(
      { "question" => question, "question_about" => [ sentence.id ] },
      facts: facts, statements: statements, turns: turns
    )
  end

  def open_case(observation)
    value = Rag::ActiveEpisode.open(correlation_id: "query:t1", now: Time.current)
    value.assign_goal!("diagnosticar la puerta", correlation_id: "query:t1")
    value.append_observation!(observation, correlation_id: "query:t1")
    value
  end

  def chunk(content)
    { content: content, metadata: { "page_number" => "8" } }
  end

  def link_reason(result)
    result.rejections.find { |row| row["part"] == "link" }&.dig("reason")
  end

  def question_reason(result)
    result.rejections.find { |row| row["part"] == "question" }&.dig("reason")
  end
end
