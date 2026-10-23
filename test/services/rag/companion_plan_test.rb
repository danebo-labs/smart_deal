# frozen_string_literal: true

require "test_helper"

class Rag::CompanionPlanTest < ActiveSupport::TestCase
  MANUAL = <<~TEXT
    [DOCUMENT: bomba.pdf]
    [SEARCH_ALIASES: el motor se para, sensor de nivel]
    [PDF_PAGE: 3]
    6.1 Averías
    • El motor se para solo.
    – Comprobar el ajuste del regulador de caudal (#9).
    – Comprobar que el sensor de nivel no esté activado.
    [PDF_PAGE: 4]
    – Si el problema persiste, desconectar el sensor de nivel y pulsar MARCHA.
    IMPORTANTE: cortar la alimentación antes de abrir la tapa.
    • El motor no arranca.
    – Comprobar la tensión de entrada.
    Etiquetas del dibujo:
    - A — bornes 1, 2
    6.2 Indicadores
    LED encendido cuando el sensor de nivel o la entrada auxiliar está activada.
    El valor de caudal es DATA_NOT_AVAILABLE en este dibujo.
    [CONFLICTO_DOCUMENTAL C9: 6.2 rotula «entrada auxiliar» y la placa rotula «AUX». REQUIRES_FIELD_VERIFICATION en la placa.]
  TEXT

  T1 = "Tengo una bomba Hidra P2. El motor se para solo. El LED está encendido. No veo agua en el sensor. No he comprobado el #9."
  T2 = "Ya revisé el sensor de nivel y no está activado."

  test "statements keep items, contiguous steps across a page mark, and their own kinds" do
    statements = Rag::CompanionStatements.parse([ chunk(MANUAL) ])
    kinds = statements.statements.to_h { |item| [ item.text, item.kind ] }

    assert_equal "heading", kinds["6.1 Averías"]
    assert_equal "item", kinds["El motor se para solo."]
    persists = statements.statements.find { |item| item.text.start_with?("Si el problema persiste") }
    assert_equal "step", persists.kind
    assert_equal "El motor se para solo.", persists.item
    assert_equal "4", persists.page
    assert_equal "warning", kinds["IMPORTANTE: cortar la alimentación antes de abrir la tapa."]
    assert_equal "text", kinds["A — bornes 1, 2"]
    assert_equal "extraction_note", kinds["El valor de caudal es DATA_NOT_AVAILABLE en este dibujo."]
    assert_equal "conflict", statements.statements.find { |item| item.text.start_with?("[CONFLICTO") }.kind
    assert_nil kinds["[DOCUMENT: bomba.pdf]"]
    assert_nil statements.statements.find { |item| item.text.include?("SEARCH_ALIASES") }
  end

  test "reference-only sources and record blocks give no statements" do
    records = "#{MANUAL}\n# FIELD-SAFETY EVIDENCE RECORDS\n\nFIELD_RECORD:\nACTION: Ajustar el #9 a 40.\nEND_FIELD_RECORD\n"
    reference = chunk("Comprobar el filtro.").merge(identity_applicability: "reference_only")
    statements = Rag::CompanionStatements.parse([ chunk(records), reference ])

    assert statements.statements.none? { |item| item.text.include?("Ajustar el #9") }
    assert_empty statements.by_source(2)
  end

  test "case facts keep an observation apart from a check and quote the technician" do
    facts = case_facts

    assert_equal %w[goal identity observation not_done_check done_check], facts.facts.map(&:kind)
    assert_equal "No he comprobado el #9.", facts.find("N1").text
    assert facts.find("N1").literal
    assert_equal "Ya revisé el sensor de nivel y no está activado.", facts.find("C1").text
    block = facts.prompt_block
    assert_includes block, "O1 [observación del técnico]: «El LED está encendido»."
    assert_includes block, "N1 [comprobación que el técnico dice no haber hecho]: «No he comprobado el #9»."
    assert_includes block, "Resultado: «no está activado»."
  end

  test "a reading must use the words of its statement and the case" do
    good = link("O1", led_statement, "con el sensor de nivel no activado, el LED encendido deja abierta la entrada auxiliar")
    invented = link("O1", led_statement, "el LED encendido indica un fallo de la placa base")

    assert_equal 1, check(links: [ good ]).links.size
    rejected = check(links: [ invented ])
    assert_empty rejected.links
    assert_match(/\Aungrounded:/, rejected.rejections.first["reason"])
  end

  test "a negation, a dropped alternative, and an exclusion are not accepted from the model" do
    negation = link("O1", led_statement, "el LED encendido no indica la entrada auxiliar")
    one_side = link("O1", led_statement, "el LED encendido indica el sensor de nivel activado")
    exclusion = link("C1", step_id("sensor de nivel no esté"), "el sensor de nivel queda descartado")

    reasons = check(links: [ negation, one_side, exclusion ]).rejections.pluck("reason")

    assert_equal %w[negation_not_grounded dropped_alternative exclusion], reasons
  end

  test "order, prescription, operations outside a step, and an unreported status are rejected" do
    order = link("O1", led_statement, "primero el LED encendido")
    prescription = link("O1", led_statement, "hay que ver el LED encendido")
    operation = link("O1", led_statement, "desconectar la entrada auxiliar con el LED encendido")
    status = link("N1", step_id("regulador"), "ya comprobado el #9")

    reasons = check(links: [ order, prescription, operation, status ]).rejections.pluck("reason")

    assert_equal %w[order prescription operation status_claim], reasons
  end

  test "a status the technician reported is accepted, and a link needs a linkable statement" do
    done = link("C1", step_id("sensor de nivel no esté"), "revisado el sensor de nivel, no está activado")
    heading = link("O1", id_of("6.1 Averías"), "")
    conflict = link("O1", statements.statements.find { |item| item.kind == "conflict" }.id, "")

    result = check(links: [ done, heading, conflict ])

    assert_equal [ "C1" ], result.links.pluck(:fact)
    assert_equal %w[statement_kind:heading statement_kind:conflict], result.rejections.pluck("reason")
  end

  test "steps must be step statements and unknown ids are dropped" do
    result = check(steps: [ step_id("regulador"), id_of("El motor se para solo."), "S9.9", step_id("regulador") ])

    assert_equal [ step_id("regulador") ], result.steps
    assert_equal %w[not_a_step unknown_statement duplicate], result.rejections.pluck("reason")
  end

  test "a question may not repeat the case, prescribe, or ask an operation that no selected step holds" do
    assert_equal "¿La entrada auxiliar tiene algo conectado?", check(question: "¿La entrada auxiliar tiene algo conectado?").question
    assert_match(/\Arepeats_fact:O1/, question_reason("¿El LED está encendido?"))
    assert_match(/\Arepeats_fact:C1/, question_reason("¿El sensor de nivel está activado?"))
    assert_equal "not_one_question", question_reason("¿El motor arranca? ¿Y la tensión?")
    assert_equal "operation", question_reason("¿Puedes desconectar el sensor de nivel?")
    persists = step_id("Si el problema persiste")
    assert_equal "¿Puedes desconectar el sensor de nivel?",
                 check(steps: [ persists ], question: "¿Puedes desconectar el sensor de nivel?").question
  end

  test "an open check already answers whether that check was performed" do
    assert_match(/\Arepeats_fact:N1/, question_reason("¿Ha comprobado el #9?"))
    assert_match(/\Arepeats_fact:N1/, question_reason("¿Verificaste el regulador de caudal #9?"))
    assert_equal "operation", question_reason("¿Ajustaste el #9?")
    assert_no_match(/\Arepeats_fact:/, question_reason("¿Qué valor marca el sensor de nivel?").to_s)

    asked = check(steps: [ step_id("regulador") ], question: "¿Ha comprobado el #9?")
    adjusted = check(steps: [ step_id("regulador") ], question: "¿Ajustaste el #9?")
    assert_nil asked.question
    assert_nil adjusted.question
    assert_not_includes render(asked), "¿Ha comprobado"
    assert_not_includes render(adjusted), "Ajustaste"
    assert_includes render(asked), "sigue pendiente"

    fuse = Rag::ActiveEpisode.open(correlation_id: "query:f2", now: Time.current)
    fuse.assign_goal!("El motor se para solo", correlation_id: "query:f2")
    fuse.upsert_check!({ "subject" => "fusible F2", "status" => "not_done" }, correlation_id: "query:f2")
    fuse.upsert_check!(
      { "subject" => "sensor de nivel", "status" => "done", "result" => "no está activado" },
      correlation_id: "query:f2"
    )
    facts = Rag::CompanionCaseFacts.build(fuse)
    repeated = Rag::CompanionPlanCheck.call(
      { "question" => "¿Ha comprobado el fusible F2?" }, facts: facts, statements: statements, turns: []
    )
    value = Rag::CompanionPlanCheck.call(
      { "question" => "¿Qué corriente marca el fusible F2?" }, facts: facts, statements: statements, turns: []
    )
    assert_match(/\Arepeats_fact:/, repeated.rejections.find { |row| row["part"] == "question" }["reason"])
    assert_no_match(/\Arepeats_fact:/, value.rejections.find { |row| row["part"] == "question" }&.dig("reason").to_s)
  end

  test "the render keeps step conditions, the case status, the warning, and the conflict note" do
    steps = [ step_id("regulador"), step_id("sensor de nivel no esté"), step_id("Si el problema persiste") ]
    result = check(
      links: [ link("O1", led_statement, "con el sensor de nivel no activado, el LED encendido deja abierta la entrada auxiliar") ],
      steps: steps,
      question: "¿La entrada auxiliar tiene algo conectado?"
    )
    text = render(result)

    assert_includes text, "Sobre lo que reportaste, «El LED está encendido»: la documentación dice «LED encendido cuando el sensor de nivel o la entrada auxiliar está activada» [1]; lectura de Danebo:"
    assert_includes text, "Para este síntoma, «El motor se para solo», la documentación indica [1]:"
    assert_includes text, "- «Comprobar el ajuste del regulador de caudal (#9)» [1]; dijiste «No he comprobado el #9», así que sigue pendiente."
    assert_includes text, "- «Comprobar que el sensor de nivel no esté activado» [1]; ya informaste: «Ya revisé el sensor de nivel y no está activado»."
    assert_includes text, "- «Si el problema persiste, desconectar el sensor de nivel y pulsar MARCHA» [1]."
    assert_includes text, "Advertencia: «IMPORTANTE: cortar la alimentación antes de abrir la tapa» [1]."
    assert_includes text, "Ojo, el documento no es coherente (C9) [1]:"
    assert_includes text, "entrada auxiliar"
    assert_includes text, "AUX"
    assert_not_includes text, "hay que verificarlo en campo"
    assert_not_includes text, "REQUIRES_FIELD_VERIFICATION"
    assert text.end_with?("¿La entrada auxiliar tiene algo conectado?")
    publication = publish(text)
    assert publication.accepted?, publication.reasons.inspect
  end

  test "an observation is never shown as a done check and a step of another symptom is conditional" do
    sensor = [ "No veo agua en el sensor de nivel", "query:t1" ]
    result = check(steps: [ step_id("sensor de nivel no esté"), step_id("tensión de entrada") ], observations: [ sensor ])
    text = render(result, observations: [ sensor ], done: false)

    assert_includes text, "reportaste «No veo agua en el sensor de nivel», que es una observación: esta comprobación no consta como hecha"
    assert_not_includes text, "ya informaste"
    assert_not_includes text, "El motor no arranca"
    assert_equal "case_unconfirmed", result.rejections.find { |item| item["part"] == "step" }["reason"]
    assert publish(text, observations: [ sensor ]).accepted?
  end

  test "a plan with nothing valid renders nothing" do
    prepared = prepared_plan
    response = CompanionPlanResponse.build({ "links" => [ { "fact" => "Z1", "statement" => "S1.1", "reading" => "" } ], "steps" => [], "question" => "" })
    composed = Rag::CompanionPlan.compose(response, prepared)

    assert_equal "", composed.text
    assert_not composed.check.usable?
    assert_equal "tool_use", composed.stop_reason
    assert_nil Rag::CompanionPlan.tool_input(Struct.new(:output).new(nil))
  end

  test "a question that names another item does not import its step" do
    skate = step_id("tensión de entrada")
    named = check(steps: [ skate ], question: "¿El motor no arranca?")
    assert_empty named.steps
    assert_equal "case_unconfirmed", named.rejections.find { |item| item["part"] == "step" }["reason"]
    assert_not_includes render(named), "Si lo que ves es «El motor no arranca»"

    dropped = check(steps: [ skate ], question: "¿La entrada auxiliar tiene algo conectado?")
    assert_empty dropped.steps
    assert_equal "case_unconfirmed", dropped.rejections.find { |item| item["part"] == "step" }["reason"]
    assert_equal "¿La entrada auxiliar tiene algo conectado?", dropped.question
  end

  test "a disambiguation question grounded in both items passes, and a foreign word does not" do
    text = "¿Se vuelve a abrir cuando el patín está cerrando?"
    manual = <<~TEXT
      • La puerta se re-abre sola.
      – Comprobar que la fotocélula no esté activada.
      • La puerta se vuelve a abrir cuando el patín está cerrando.
      – Comprobar la regulación del patín.
    TEXT
    statements = Rag::CompanionStatements.parse([ chunk(manual) ])
    skate = statements.statements.find { |item| item.step? && item.text.include?("patín") }
    result = Rag::CompanionPlanCheck.call(
      { "links" => [], "steps" => [ skate.id ], "question" => text },
      facts: case_facts, statements: statements, turns: turns
    )

    assert_equal text, result.question
    assert_empty result.steps
    assert_equal "case_unconfirmed", result.rejections.find { |item| item["part"] == "step" }["reason"]
    foreign = Rag::CompanionPlanCheck.call(
      { "links" => [], "steps" => [], "question" => "¿El patín está oscilando?" },
      facts: case_facts, statements: statements, turns: turns
    )
    assert_nil foreign.question
    assert_match(/\Aungrounded:/, foreign.rejections.find { |item| item["part"] == "question" }["reason"])
  end

  test "an empty reading still rejects a different operation and a partial report does not apply the result" do
    review = link("C1", step_id("desconectar el sensor"), "")
    rejected = check(links: [ review ], steps: [ step_id("desconectar el sensor") ])
    assert_equal [ "operation_mismatch" ], rejected.rejections.select { |item| item["part"] == "link" }.pluck("reason")
    text = render(rejected)
    assert_not_includes text, "ya informaste"
    assert_includes text, "También informaste: «Ya revisé el sensor de nivel y no está activado»."

    sentence = "Desconecté el sensor de nivel, todavía no pulsé MARCHA."
    partial_manual = <<~TEXT
      • El motor se para solo.
      – En caso que el problema persista, desconectar el sensor de nivel y pulsar MARCHA. Si el motor no arranca, debe haber una obstrucción mecánica en la puerta.
    TEXT
    statements = Rag::CompanionStatements.parse([ chunk(partial_manual) ])
    step = statements.statements.find(&:step?)
    assert_equal :partial, Rag::ReportedOperation.correspondence(
      report_text: sentence, result: nil, status: "done", statement_text: step.text
    )
    value = Rag::ActiveEpisode.open(correlation_id: "query:t2", now: Time.current)
    value.assign_goal!("El motor se para solo", correlation_id: "query:t2")
    value.upsert_check!({ "subject" => "sensor de nivel", "status" => "done", "operation" => [ "disconnect" ] }, correlation_id: "query:t2")
    local_session = Struct.new(:conversation_history).new([
      { "role" => "user", "content" => sentence, "correlation_id" => "query:t2" }
    ])
    local = Rag::CompanionCaseFacts.build(value, session: local_session)
    rendered = Rag::CompanionPlanRender.call(
      Rag::CompanionPlanCheck.call(
        { "links" => [], "steps" => [ step.id ], "question" => "" },
        facts: local, statements: statements, turns: []
      ),
      facts: local, statements: statements
    )
    assert_includes rendered, "no completa esta operación"
    assert_not_includes rendered, "debe haber una obstrucción mecánica"
    assert_not_includes rendered, "ya informaste"
  end

  test "the prepared call is one forced tool call with the case, the turns, and the numbered statements" do
    prepared = prepared_plan

    assert_equal Rag::CompanionPlan::TOOL_NAME, prepared.params.dig(:tool_config, :tool_choice, :tool, :name)
    assert_equal 0, prepared.params.dig(:inference_config, :temperature)
    assert_includes prepared.system, "reading no menciona ids"
    assert_includes prepared.user, "Mensaje de este turno:\n¿qué sigue?"
    assert_includes prepared.user, "C1 [comprobación que el técnico dice haber hecho]"
    assert_includes prepared.user, T1
    assert_includes prepared.user, "(paso de «El motor se para solo.»): Si el problema persiste"
    assert_not_includes prepared.user, "FIELD_RECORD"
  end

  private

  def chunk(content, page: "3")
    {
      content: content,
      metadata: { "canonical_name" => "Manual bomba P2", "page_number" => page, "original_source_uri" => "s3://example/bomba.pdf" },
      identity_applicability: "compatible"
    }
  end

  def statements
    @statements ||= Rag::CompanionStatements.parse([ chunk(MANUAL) ])
  end

  def id_of(text)
    statements.statements.find { |item| item.text == text }.id
  end

  def step_id(fragment)
    statements.statements.find { |item| item.step? && item.text.include?(fragment) }.id
  end

  def led_statement
    statements.statements.find { |item| item.text.start_with?("LED encendido") }.id
  end

  def link(fact, statement, reading)
    { "fact" => fact, "statement" => statement, "reading" => reading }
  end

  def episode(observations: [ [ "El LED está encendido", "query:t1" ] ], done: true)
    value = Rag::ActiveEpisode.open(correlation_id: "query:t1", now: Time.current)
    value.assign_goal!("El motor se para solo", correlation_id: "query:t1")
    value.write_fact!("manufacturer", status: "known", value: "Hidra", source: "user", correlation_id: "query:t1", at: Time.current.iso8601)
    observations.each { |text, id| value.append_observation!(text, correlation_id: id) }
    value.upsert_check!({ "subject" => "#9", "status" => "not_done" }, correlation_id: "query:t1")
    if done
      value.upsert_check!({ "subject" => "sensor de nivel", "status" => "done", "result" => "no está activado" }, correlation_id: "query:t2")
    end
    value
  end

  def session
    @session ||= Struct.new(:conversation_history) do
      def episode_history_cutoff(_now = nil)
        1.hour.ago
      end
    end.new([
      { "role" => "user", "content" => T1, "correlation_id" => "query:t1", "ts" => 3.minutes.ago.iso8601 },
      { "role" => "user", "content" => T2, "correlation_id" => "query:t2", "ts" => 2.minutes.ago.iso8601 },
      { "role" => "user", "content" => "¿qué sigue?", "correlation_id" => "query:t3", "ts" => 1.minute.ago.iso8601 }
    ])
  end

  def case_facts(**options)
    Rag::CompanionCaseFacts.build(episode(**options), session: session)
  end

  def turns
    [ T1, T2, "¿qué sigue?" ]
  end

  def check(links: [], steps: [], question: "", observations: nil)
    facts = observations ? case_facts(observations: observations, done: false) : case_facts
    Rag::CompanionPlanCheck.call(
      { "links" => links, "steps" => steps, "question" => question },
      facts: facts, statements: statements, turns: turns
    )
  end

  def question_reason(question)
    check(question: question).rejections.find { |item| item["part"] == "question" }&.dig("reason")
  end

  def render(result, observations: nil, done: true)
    facts = observations ? case_facts(observations: observations, done: done) : case_facts
    Rag::CompanionPlanRender.call(result, facts: facts, statements: statements)
  end

  def publish(text, observations: nil)
    parsed = observations ? episode(observations: observations, done: false) : episode
    technician = turns + [ parsed.goal["text"] ] + parsed.observations.pluck("text") +
                 parsed.checks.flat_map { |item| [ item["subject"], item["result"] ] }.compact + [ "Hidra" ]
    Rag::CompanionTurnPublication.call(
      text: text,
      sources: [ { "index" => 1, "content" => MANUAL, "applicability" => "compatible", "reference_only" => false } ],
      technician_texts: technician,
      manufacturer: "Hidra"
    )
  end

  def prepared_plan
    Rag::CompanionPlan.prepare(
      raw_question: "¿qué sigue?", chunks: [ chunk(MANUAL) ], episode: episode, session: session,
      correlation_id: "query:t3"
    )
  end
end

require_relative "../../support/companion_plan_response"
