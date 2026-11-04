# frozen_string_literal: true

require "test_helper"

# Applicability is a documentary answer. The model names the rule and the
# status of each literal condition. These tests use the captured T3 negation
# and a second manual. They do not call a model, and they do not treat a
# stem, a terminal, or a nearby word as coverage.
class Rag::CompanionApplicabilityTest < ActiveSupport::TestCase
  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/vf5_guion2_t3/turn.json").read)
  TURN = FIXTURE.fetch("turn")
  CONDITION = FIXTURE.fetch("manual_condition")
  REPEATED = FIXTURE.fetch("planner_question")
  GLOBAL = "no se cumple ninguna condición de esta regla"
  ACTION = "realizar otra vez el autoajuste"
  OPEN_CONCLUSION = "Si tampoco hubo otros cambios de ese tipo, según S1.9 no corresponde lo que esa regla condiciona."
  ACTION_CONCLUSION = "Si tampoco hubo otros cambios de ese tipo, según S1.9 no corresponde «#{ACTION}»."
  PARTIAL_LINE = "«o cuando se realicen cambios como la conexión o desconexión de la fotocélula Fermator» [1]: lo que dijiste, «No he cambiado la configuración ni conectado o desconectado la fotocélula», cubre «la conexión o desconexión de la fotocélula Fermator»; otros cambios de ese tipo siguen sin confirmarse."
  LIVE = Rails.root.join("tmp/field_companion/vf5_companion_integration/t3_applicability_live.json")
  SECTION = <<~TEXT
    5.8 Pulsador de autoajuste (51)
    El pulsador de Autoajuste se utiliza para instalar la puerta.
    Con un motor PM instalado el autoajuste ha de hacerse con la puerta de cabina acoplada y con la puerta de rellano.
    Con un motor asíncrono instalado el autoajuste ha de hacerse con la puerta de cabina acoplada pero sin la puerta de rellano.
    La puerta realizarán 5 movimientos para detectar el motor y el paso libre.
    De la información obtenida el microprocesador calculará las rampas de aceleración y desaceleración para dar un control óptimo a la puerta.
    Una vez el autoajuste se haya completado los parámetros serán guardados en una EEPROM no-volátil.
    Las puertas se abrirán lentamente en la primera operación después de un fallo de alimentación para verificar el paso libre.
    #{CONDITION}
  TEXT
  OTHER_RULE = "Repetir la prueba de la central solo después de un cambio de firmware o cuando se hagan intervenciones como el reemplazo del sensor de humo."
  OTHER_TURN = "No reemplacé el sensor de humo. ¿Hay que repetir la prueba de la central?"

  test "a synthetic applicability publishes the rule, keeps the conclusion conditional, and drops the repeated question" do
    episode = apply_captured_turn
    checked = check(t3_plan, episode, TURN)
    text = render(checked, episode)

    assert_equal "S1.9", checked.applicability["statement"]
    assert_equal "8", checked.applicability["page"]
    assert_equal "conditional", checked.applicability["conclusion"]
    assert_equal "repeats_declaration", question_reason(checked)
    assert_nil checked.question
    assert_not_includes checked.steps, "S1.9"
    assert_includes checked.rejections.pluck("reason"), "not_a_step"
    assert checked.usable?
    assert text.start_with?("Sobre lo que preguntas")
    assert_includes text, CONDITION.delete_suffix(".")
    assert_includes text, "página 8"
    assert_includes text, "No he cambiado la configuración"
    assert_includes text, "ni conectado o desconectado la fotocélula"
    assert_includes text, "cambios como"
    assert_equal %w[parcial parcial parcial], checked.applicability["conditions"].pluck("status")
    assert_includes text, "esa parte sigue sin confirmarse"
    assert_not_includes text, "descarta esta condición"
    assert_not_includes text, "lo que queda abierto"
    assert_not_includes text, "otros cambios"
    assert_not_includes text, GLOBAL
    assert_not_includes text, "no hace falta"
    assert_not_includes text, "conexiones"
    assert_not_includes text, REPEATED
    assert text.index("Sobre lo que preguntas") < text.index("Sobre lo que reportaste")
  end

  test "an omitted or truncated condition does not discard the whole rule" do
    episode = apply_captured_turn
    omitted = check(plan_with([
      condition("la conexión o desconexión de la fotocélula Fermator", "descartada", "ni conectado o desconectado la fotocélula")
    ]), episode, TURN)
    truncated = check(plan_with([
      condition("configuración", "descartada", "No he cambiado la configuración"),
      condition("la conexión o desconexión de la fotocélula Fermator", "descartada", "ni conectado o desconectado la fotocélula")
    ]), episode, TURN)

    [ omitted, truncated ].each do |checked|
      text = render(checked, episode)

      assert_equal "conditional", checked.applicability["conclusion"]
      assert_equal "S1.9", checked.applicability["statement"]
      assert_includes text, CONDITION.delete_suffix(".")
      assert_includes text, "página 8"
      assert_not_includes text, GLOBAL
    end
    assert_equal [ "configuración" ], truncated.applicability["conditions"].pluck("text").grep("configuración")
    assert_equal "descartada", truncated.applicability["conditions"].find { |row| row["text"] == "configuración" }["status"]
    assert_equal "parcial", truncated.applicability["conditions"].find { |row| row["text"].include?("fotocélula") }["status"]
    assert_equal "parcial", omitted.applicability["conditions"].sole["status"]
  end

  test "an invalid technician quote leaves the conclusion open" do
    episode = apply_captured_turn
    checked = check(plan_with([
      condition(CONDITION, "descartada", "nunca moví el puente del tablero")
    ]), episode, TURN)
    text = render(checked, episode)

    assert_equal "conditional", checked.applicability["conclusion"]
    assert_empty checked.applicability["conditions"]
    assert_equal "citation", checked.rejections.find { |row| row["part"] == "applicability" }["reason"]
    assert_includes text, CONDITION.delete_suffix(".")
    assert_includes text, "Queda abierto lo que esta regla condiciona"
    assert_not_includes text, GLOBAL
  end

  test "denying one example of another manual's open rule does not discard that rule" do
    turn = OTHER_TURN
    episode = apply_turn(turn)
    statements = other_statements
    checked = Rag::CompanionPlanCheck.call(
      {
        "steps" => [],
        "question" => "",
        "applicability" => {
          "statement" => "S1.2",
          "conditions" => [
            condition("un cambio de firmware", "abierta", ""),
            condition("el reemplazo del sensor de humo", "descartada", "No reemplacé el sensor de humo")
          ]
        }
      },
      facts: facts_for(episode), statements: statements, turns: [ turn ]
    )
    text = render(checked, episode, statements)

    sensor = checked.applicability["conditions"].find { |row| row["text"].include?("sensor de humo") }
    firmware = checked.applicability["conditions"].find { |row| row["text"].include?("firmware") }

    assert_equal "S1.2", checked.applicability["statement"]
    assert_equal OTHER_RULE, statements.find("S1.2").text
    assert_equal "conditional", checked.applicability["conclusion"]
    assert_equal "parcial", sensor["status"]
    assert_equal "abierta", firmware["status"]
    assert_includes text, OTHER_RULE.delete_suffix(".")
    assert_includes text, "No reemplacé el sensor de humo"
    assert_includes text, "intervenciones como"
    assert_includes text, "no contiene «el reemplazo del sensor de humo»; esa parte sigue sin confirmarse"
    assert_includes text, "Sigue sin confirmarse «un cambio de firmware» y «el reemplazo del sensor de humo»."
    assert_not_includes text, "otros cambios"
    assert_not_includes text, "descarta esta condición"
    assert_not_includes text, "lo que queda abierto"
    assert_not_includes text, GLOBAL
    assert_not_includes checked.steps, "S1.2"
  end

  test "a question about a different datum stays, and a plan without applicability does not change" do
    episode = apply_captured_turn
    question = "¿El motor instalado es PM o asíncrono?"
    motor = statements.statements.find { |row| row.text.include?("motor PM") }
    plain = { "question" => question, "question_about" => [ motor.id ] }
    empty = plain.merge("applicability" => { "statement" => "", "conditions" => [] })
    with_rule = plain.merge("applicability" => {
      "statement" => "S1.9",
      "conditions" => [
        condition("la configuración de los parámetros por defecto", "descartada", "No he cambiado la configuración")
      ]
    })

    [ plain, empty ].each do |plan|
      checked = check(plan, episode, TURN)

      assert_nil checked.applicability
      assert_equal question, checked.question
    end
    assert_equal render(check(plain, episode, TURN), episode), render(check(empty, episode, TURN), episode)

    kept = check(with_rule, episode, TURN)
    text = render(kept, episode)

    assert_equal question, kept.question
    assert_nil question_reason(kept)
    assert_includes text, question
    assert_includes text, "Para orientar falta un dato"
    assert_not_includes text, "conexiones"
  end

  test "a question already answered stays blocked when an applicability is also proposed" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:answered", now: Time.current)
    episode.assign_goal!("La central no responde", correlation_id: "query:answered")
    question = "¿El sensor de humo está en fallo?"
    episode.append_observation!(
      "El sensor no suena",
      correlation_id: "query:answered",
      answers: {
        "q" => question,
        "r" => "no",
        "t" => [ { "item" => "Sensor de humo", "page" => "2" } ]
      }
    )
    statements = Rag::CompanionStatements.parse([
      {
        content: "• Sensor de humo\nCerrar si el sensor de humo está en fallo.",
        metadata: { "page_number" => "2" }
      }
    ])
    item = statements.statements.find { |row| row.kind == "item" }
    checked = Rag::CompanionPlanCheck.call(
      {
        "question" => question,
        "question_about" => [ item.id ],
        "applicability" => {
          "statement" => statements.statements.find { |row| row.kind == "text" }.id,
          "conditions" => [ condition("el sensor de humo está en fallo", "abierta", "") ]
        }
      },
      facts: facts_for(episode), statements: statements, turns: [ question ]
    )

    assert_equal "already_answered", question_reason(checked)
    assert_nil checked.question
    assert_not_includes render(checked, episode, statements), question
  end

  test "a quote that literally contains every word of the rule can discard it" do
    rule = "Cerrar si hay humo o si hay calor."
    turn = "Confirmado: #{rule}"
    episode = apply_turn(turn)
    statements = Rag::CompanionStatements.parse([
      { content: rule, metadata: { "page_number" => "3" } }
    ])
    checked = Rag::CompanionPlanCheck.call(
      {
        "applicability" => {
          "statement" => "S1.1",
          "conditions" => [ condition(rule, "descartada", turn) ]
        }
      },
      facts: facts_for(episode), statements: statements, turns: [ turn ]
    )
    text = render(checked, episode, statements)

    assert_equal "discarded", checked.applicability["conclusion"]
    assert_equal "descartada", checked.applicability["conditions"].sole["status"]
    assert_includes text, rule.delete_suffix(".")
    assert_includes text, "descarta esta condición"
    assert_includes text, GLOBAL
    assert checked.usable?
    assert_not_includes text, "otros cambios"
    assert_not_includes text, "lo que queda abierto"
    assert_not_includes text, OPEN_CONCLUSION
  end

  test "a covered fragment stays discarded and the open fragment is named from the rule" do
    rule = "Cerrar si hay humo o si hay calor."
    turn = "No hay humo."
    episode = apply_turn(turn)
    statements = Rag::CompanionStatements.parse([
      { content: rule, metadata: { "page_number" => "3" } }
    ])
    checked = Rag::CompanionPlanCheck.call(
      {
        "applicability" => {
          "statement" => "S1.1",
          "conditions" => [
            condition("hay humo", "descartada", "No hay humo"),
            condition("hay calor", "abierta", "")
          ]
        }
      },
      facts: facts_for(episode), statements: statements, turns: [ turn ]
    )
    text = render(checked, episode, statements)

    assert_equal "descartada", checked.applicability["conditions"].find { |row| row["text"] == "hay humo" }["status"]
    assert_equal "abierta", checked.applicability["conditions"].find { |row| row["text"] == "hay calor" }["status"]
    assert_equal "conditional", checked.applicability["conclusion"]
    assert_includes text, "«hay humo» [1]: lo que dijiste, «No hay humo», descarta esta condición."
    assert_includes text, "Sigue sin confirmarse «hay calor»."
    assert_not_includes text, "lo que queda abierto"
    assert_not_includes text, "otros cambios"
    assert_not_includes text, GLOBAL
  end

  test "the captured T3 plan lowers the photocell condition and does not publish the repeated question" do
    plan = live_plan
    raw = plan.fetch("applicability")
    episode = apply_captured_turn
    checked = check(plan, episode, TURN)
    text = render(checked, episode)
    asked = live_plan
    asked["question"] = REPEATED
    asked["question_about"] = [ "S1.9" ]
    questioned = check(asked, episode, TURN)

    assert_nil raw["action"]
    assert_equal "", raw["conditions"][0]["said"]
    assert_equal "descartada", raw["conditions"][1]["status"]
    assert_equal "citation", checked.rejections.find { |row| row["part"] == "applicability" && row["reason"] == "citation" }["reason"]
    assert_equal 1, checked.applicability["conditions"].size
    assert_equal "parcial", checked.applicability["conditions"].sole["status"]
    assert_includes checked.applicability["conditions"].sole["text"], "cambios como la conexión o desconexión de la fotocélula"
    assert_equal "conditional", checked.applicability["conclusion"]
    assert_equal "S1.9", checked.applicability["statement"]
    assert_equal "8", checked.applicability["page"]
    assert_nil checked.applicability["action"]
    assert_equal captured_text(OPEN_CONCLUSION), text
    assert_equal "repeats_declaration", question_reason(questioned)
    assert_nil questioned.question
    assert_not_includes render(questioned, episode), REPEATED
    assert_not_includes text, "descarta esta condición"
    assert_not_includes text, "lo que queda abierto"
    assert_not_includes text, "no hace falta"
  end

  test "a synthetic action on the captured plan names the autoajuste and an invalid action is dropped" do
    episode = apply_captured_turn
    valid = live_plan
    valid["applicability"]["action"] = "  #{ACTION}  "
    checked = check(valid, episode, TURN)
    text = render(checked, episode)
    invalid = live_plan
    invalid["applicability"]["action"] = "repetir el autoajuste"
    rejected = check(invalid, episode, TURN)
    rejected_text = render(rejected, episode)

    assert_equal ACTION, checked.applicability["action"]
    assert_equal "parcial", checked.applicability["conditions"].sole["status"]
    assert_equal "conditional", checked.applicability["conclusion"]
    assert_equal "S1.9", checked.applicability["statement"]
    assert_equal "8", checked.applicability["page"]
    assert_equal captured_text(ACTION_CONCLUSION), text
    assert_includes text, "autoajuste"
    assert_includes text, "otros cambios de ese tipo siguen sin confirmarse"
    assert_includes text, "la conexión o desconexión de la fotocélula"
    assert_equal "action:not_literal", rejected.rejections.find { |row| row["reason"] == "action:not_literal" }["reason"]
    assert_equal "repetir el autoajuste", rejected.rejections.find { |row| row["reason"] == "action:not_literal" }["value"]
    assert_nil rejected.applicability["action"]
    assert_equal "parcial", rejected.applicability["conditions"].sole["status"]
    assert_equal "conditional", rejected.applicability["conclusion"]
    assert_equal captured_text(OPEN_CONCLUSION), rejected_text
    assert_not_includes rejected_text, "repetir el autoajuste"
    assert_not_includes rejected_text, "descarta esta condición"

    blank = live_plan
    blank["applicability"]["action"] = "   "
    blank_checked = check(blank, episode, TURN)

    assert_nil blank_checked.applicability["action"]
    assert_nil blank_checked.rejections.find { |row| row["reason"] == "action:not_literal" }
    assert_equal captured_text(OPEN_CONCLUSION), render(blank_checked, episode)
  end

  test "the prompt asks for applicability and an old plan without it still loads" do
    prompt = Rails.root.join("app/prompts/bedrock/companion_plan.txt").read
    schema = Rag::CompanionPlan::TOOL_SCHEMA

    assert_includes prompt, "Las frases «Dicho por el técnico» también son el caso."
    assert_includes prompt, "applicability:"
    assert_includes prompt, "action es un fragmento literal de esa afirmación que nombra la acción, o queda vacío."
    assert_includes schema["required"], "applicability"
    applicability = schema.dig("properties", "applicability")
    assert_equal %w[statement conditions], applicability["required"]
    assert_equal "Fragmento literal de la regla que nombra la acción, o vacío.", applicability.dig("properties", "action", "description")
    assert_equal %w[descartada parcial abierta], applicability.dig("properties", "conditions", "items", "properties", "status", "enum")

    episode = apply_captured_turn
    checked = check({ "question" => REPEATED, "steps" => [ "S1.9" ] }, episode, TURN)

    assert_nil checked.applicability
    assert_equal "repeats_declaration", question_reason(checked)
    assert_equal [ "not_a_step" ], checked.rejections.select { |row| row["part"] == "step" }.pluck("reason")
  end

  private

  def live_plan
    JSON.parse(LIVE.read).fetch("tool_input")
  end

  def captured_text(conclusion)
    [
      "Sobre lo que preguntas, la documentación dice «#{CONDITION.delete_suffix(".")}» [1], página 8.",
      PARTIAL_LINE,
      conclusion
    ].join("\n")
  end

  def t3_plan
    plan_with([
      condition("la configuración de los parámetros por defecto", "descartada", "No he cambiado la configuración"),
      condition("cambios como", "parcial", "ni conectado o desconectado la fotocélula"),
      condition("la conexión o desconexión de la fotocélula Fermator", "descartada", "ni conectado o desconectado la fotocélula")
    ]).merge(
      "links" => [ { "fact" => "G1", "statement" => "S1.8", "reading" => "" } ],
      "steps" => %w[S1.8 S1.9],
      "question" => REPEATED,
      "question_about" => [ "S1.9" ]
    )
  end

  def plan_with(conditions)
    { "applicability" => { "statement" => "S1.9", "conditions" => conditions } }
  end

  def condition(text, status, said)
    { "text" => text, "status" => status, "said" => said }
  end

  def apply_captured_turn
    episode = Rag::ActiveEpisode.open(correlation_id: "query:t1", now: Time.current)
    episode.assign_goal!(
      "Después de un corte de alimentación, al volver la corriente la puerta abrió muy despacio",
      correlation_id: "query:t1"
    )
    apply_turn(TURN, episode, FIXTURE.fetch("interpreter"))
  end

  def apply_turn(turn, episode = nil, raw = nil)
    episode ||= Rag::ActiveEpisode.open(correlation_id: "query:t3", now: Time.current)
    perception = Rag::TurnPerception.build(
      raw || { "move" => "follow_up", "assertions" => [], "observations" => [], "checks" => [],
               "pending_resolution" => nil, "clarification_target" => nil, "part_replies" => [] },
      turn: turn, episode: episode, catalog: nil, viewer_account: nil
    )
    decision = Struct.new(:decision, :pending_question) do
      def performs_retrieval? = true
    end.new("retrieve", nil)
    Rag::WorkContextReducer.apply!(
      episode: episode, perception: perception, decision: decision,
      turn: turn, correlation_id: "query:t3", now: Time.current
    )
    episode
  end

  def check(plan, episode, turn)
    Rag::CompanionPlanCheck.call(plan, facts: facts_for(episode), statements: statements, turns: [ turn ])
  end

  def render(checked, episode, parsed = statements)
    Rag::CompanionPlanRender.call(checked, facts: facts_for(episode), statements: parsed)
  end

  def facts_for(episode)
    Rag::CompanionCaseFacts.build(episode, session: Object.new)
  end

  def statements
    @statements ||= Rag::CompanionStatements.parse([
      { content: SECTION, metadata: { "page_number" => "8" } }
    ])
  end

  def other_statements
    @other_statements ||= Rag::CompanionStatements.parse([
      {
        content: "4.2 Prueba de la central\n#{OTHER_RULE}",
        metadata: { "page_number" => "4" }
      }
    ])
  end

  def question_reason(result)
    result.rejections.find { |row| row["part"] == "question" }&.dig("reason")
  end
end
