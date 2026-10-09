# frozen_string_literal: true

require "test_helper"

class Rag::CompanionGuidanceContextTest < ActiveSupport::TestCase
  test "bounds the turn to the problem, the photo, and the missing manual" do
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "Orona",
      needles: [ "Orona", "PBCM-V3" ],
      facts: [
        { "slot" => "manufacturer", "value" => "Orona", "source" => "photo", "correlation_id" => "photo:1" },
        { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "photo:1" }
      ]
    )
    session_context = <<~TEXT
      ## Active Field Problem
      Goal: no nivela en planta 3
      These facts identify the job. Procedures, values, terminals and code meanings still come only from retrieved evidence.
      ## Photo Evidence (this turn)
      The technician attached a photo. Procedures and values come only from the retrieved manuals.
      - Component: Placa controladora
      - Manufacturer: Orona
      - Model: PBCM-V3
      - Subsystem: CONTROLLER_LOGIC
      - Visible text/codes: UNKNOWN
      - Condition: GOOD
      ## Recent Conversation
      User: Ahora estoy revisando otro ascensor.
      Assistant: Hola. ¿Qué está pasando?
      User: #{ "detalle " * 80 }
    TEXT
    prompt = Rag::CompanionGuidanceContext.build(
      question: "la consulta anterior, de eso estoy hablando",
      identity: identity,
      session_context: session_context,
      labels: [
        "REFERENCE ONLY — OTHER EQUIPMENT: Fuji Yida Guía del Usuario Ascensor",
        "REFERENCE ONLY — OTHER EQUIPMENT: Código de Avería BLT Ascensor"
      ],
      locale: :es
    ).to_s

    assert_includes prompt, "# FIELD COMPANION"
    assert_includes prompt, "no nivela en planta 3"
    assert_includes prompt, "Accepted visual observation:"
    assert_includes prompt, "Manufacturer: Orona"
    assert_includes prompt, "Model: PBCM-V3"
    assert_includes prompt, "Subsystem: CONTROLLER_LOGIC"
    assert_includes prompt, "Condition: GOOD"
    assert_not_includes prompt, "Visible text"
    assert_not_includes prompt, "UNKNOWN"
    assert_includes prompt, "No compatible manufacturer manual was found."
    assert_includes prompt, "Fuji Yida"
    assert_includes prompt, "Do not teach their contents."
    assert_includes prompt, "Follow-up: yes."
    assert_includes prompt, "One main question"
    assert_includes prompt, "do not choose a manufacturer"
    assert_not_includes prompt, "Hola. ¿Qué está pasando?"
    assert_not_includes prompt, "Procedures and values come only from the retrieved manuals."
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
  end

  test "safety evidence is only the accepted visual values" do
    context = Rag::CompanionGuidanceContext.build(
      question: "no nivela",
      identity: Rag::EquipmentIdentity.new(
        manufacturer: "KONE",
        needles: [ "KONE" ],
        facts: [ { "slot" => "manufacturer", "value" => "KONE", "source" => "user", "correlation_id" => "q" } ],
        conflicts: [ { "fact" => "manufacturer", "user" => "KONE", "photo" => "Orona", "correlation_id" => "photo:1" } ]
      ),
      session_context: <<~TEXT,
        ## Photo Evidence (this turn)
        - Manufacturer: Orona
        - Model: PBCM-V3
        - Visible text/codes: X17
      TEXT
      labels: [ "REFERENCE ONLY — OTHER EQUIPMENT: Fuji Yida" ],
      locale: :es
    )

    assert_equal "Orona\nPBCM-V3\nX17", context.safety_evidence
    assert_includes context.to_s, "technician said KONE"
    assert_includes context.to_s, "the photo shows Orona"
    assert_not_includes context.safety_evidence, "KONE"
    assert_not_includes context.safety_evidence, "Fuji"
  end

  test "unknown identity guidance withholds chunk bodies and prior assistant prose" do
    sentinel = "SENTINEL_XQ7_BORNE cortar tensión en el borne XQ7"
    session_context = <<~TEXT
      ## Session Focus
      The technician has explicitly pinned the following documents. Ground your answer in SEGURIDAD IN.
      ## Active Field Problem (technician-stated job state, not documentary evidence)
      Goal: la puerta 1 no termina de cerrar
      Manufacturer: Elemont (catalog)
      These facts identify the job. Procedures, values, terminals and code meanings still come only from retrieved evidence.
      ## Photo Evidence (this turn)
      - Visible text/codes: TEST OK
      ## Recent Conversation
      User: Ya comprobé la guía.
      Assistant: Paso 11. Ajusta el interruptor a 2,5 mm. #{sentinel}
    TEXT
    prompt = Rag::CompanionGuidanceContext.build(
      question: "¿Qué reviso?",
      identity: nil,
      session_context: session_context,
      labels: [],
      locale: :es,
      mode: :unknown,
      manuals: [ "Elemont Montacargas Hidraulico Modelo MH, p. 1" ]
    ).to_s

    assert_includes prompt, "# FIELD COMPANION"
    assert_includes prompt, "The equipment identity is not confirmed."
    assert_includes prompt, "Those contents are not in this prompt."
    assert_includes prompt, "Question: ¿Qué reviso?"
    assert_includes prompt, "Goal: la puerta 1 no termina de cerrar"
    assert_includes prompt, "Manufacturer: Elemont (catalog)"
    assert_includes prompt, "Ya comprobé la guía."
    assert_includes prompt, "not confirmed for this equipment"
    assert_includes prompt, "Contents withheld"
    assert_includes prompt, "Elemont Montacargas Hidraulico Modelo MH, p. 1"
    assert_not_includes prompt, sentinel
    assert_not_includes prompt, "APPLICABILITY_BLOCK"
    assert_not_includes prompt, "identity_unknown_reference"
    assert_not_includes prompt, "Paso 11"
    assert_not_includes prompt, "## Session Focus"
    assert_not_includes prompt, "Ground your answer"
    assert_not_includes prompt, "These facts identify the job"
    assert_includes prompt, "Follow-up: yes."
    held = context_for_unknown_fixture(session_context)
    held.to_s
    assert_not held.context_truncated?
    assert_equal "advance_fault", held.turn_objective
    assert_equal "default_fault_progress", held.turn_objective_basis
    assert_includes prompt, "You are assisting an elevator technician in the field."
    assert_includes prompt, "Keep this job in elevator field service."
    assert_not_includes prompt, "another kind of machine"
    assert_includes prompt, "You may ask one safe look, read, or listen check tied to the reported symptom."
    assert_includes prompt, "in the same sentence"
    assert_includes prompt, "One main question"
    assert_includes prompt, "Do not make a questionnaire."
    assert_includes prompt, "do not reply by only asking which equipment this is"
    assert_includes prompt, "already report an action as done"
    assert_includes prompt, "Do not stop at the refusal"
    assert_includes prompt, "Do not choose the nameplate or the equipment identity as the main question."
    assert_not_includes prompt, "If the missing fact is which equipment this is, ask them to read the nameplate"
    assert_not_includes prompt, "Ask them to read the nameplate"
    assert_includes prompt, "Mark a hypothesis as a hypothesis."
    assert_includes prompt, "A summary of what was verified and the missing documentation is a complete answer."
    assert_not_includes prompt, "Catalog entry"
    assert_not_includes prompt, "Do not propose another check by routine."
    assert_includes prompt, "tool or instrument measurement without applicable evidence."
    assert_includes prompt, "selectors, waits, inspection mode, power cuts, or resets."
    assert_includes prompt, "Do not print DATA_NOT_AVAILABLE."
    assert_includes prompt, "Do not cite manuals with [n]."
    assert_includes prompt, "Write the entire answer in Spanish."
    assert_not_includes prompt, Rag::CompanionGuidanceContext::COMPANION_POLICY_VERSION
    assert_not_includes prompt, "SI-2"
    assert_not_includes prompt, "XQ7"
    assert_not_includes prompt, "Enviar la cabina"
    assert_not_includes prompt, "Procedimiento de rescate"
  end

  test "guidance separates reported facts from a hypothesis about an unestablished part" do
    unknown = unknown_prompt(question: "la puerta no cierra", session_context: "Goal: la puerta no cierra", locale: :es)
    known = Rag::CompanionGuidanceContext.build(
      question: "la puerta no cierra",
      identity: Rag::EquipmentIdentity.new(manufacturer: nil, needles: [], facts: []),
      session_context: "Goal: la puerta no cierra",
      labels: [],
      locale: :es
    ).to_s
    rule = Rag::CompanionGuidanceContext::HYPOTHESIS_RULE

    assert_includes unknown, rule
    assert_includes known, rule
    assert_includes rule, "the report"
    assert_includes rule, "the evidence"
    assert_includes rule, "a hypothesis"
    assert_includes rule, "unestablished part or place"
    assert_not_includes unknown, "sensor de cierre"
    assert_not_includes unknown, "jamba"
    assert_includes unknown, "Do not make a questionnaire."
    assert_includes unknown, "Do not ask equipment identity by routine."
  end

  test "an unknown answer or a bare follow-up can close without another routine check" do
    [ "¿Y ahora? No lo sé.", "Sigue igual.", "Sigue igual. ¿Y ahora?" ].each do |question|
      unknown = unknown_prompt(question: question, session_context: "Goal: la puerta no cierra", locale: :es)
      known = Rag::CompanionGuidanceContext.build(
        question: question,
        identity: Rag::EquipmentIdentity.new(
          manufacturer: "Elemont",
          needles: [ "Elemont" ],
          facts: [ { "slot" => "manufacturer", "value" => "Elemont", "source" => "user" } ]
        ),
        session_context: "Goal: la puerta no cierra",
        labels: [],
        locale: :es,
        mode: :known
      ).to_s

      [ unknown, known ].each do |prompt|
        assert_includes prompt, "Do not propose another check by routine.", question
        assert_includes prompt, "recommend escalation", question
        assert_not_includes prompt, "Catalog entry", question
        assert_not_includes prompt, "You may ask one safe look", question
      end
    end

    summary = unknown_prompt(
      question: "Resúmeme lo que llevamos y dime qué observación segura sigue.",
      session_context: "Goal: la puerta no cierra",
      locale: :es
    )
    assert_not_includes summary, "Do not propose another check by routine."
    assert_includes summary, "A summary of what was verified and the missing documentation is a complete answer."
  end

  test "unknown guidance keeps locale follow-up and the prompt budget" do
    prompt = unknown_prompt(question: "", session_context: "", locale: :es)
    instruction = prompt.sub(/\n\nFollow-up: no\.\z/, "")

    assert_operator instruction.length, :<, Rag::CompanionGuidanceContext::MAX_CHARS
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
    assert_includes prompt, "Write the entire answer in Spanish."
    assert_includes prompt, "Follow-up: no."
    english = unknown_prompt(question: "the door will not close", session_context: "", locale: :en)
    assert_includes english, "Write the entire answer in English."
    assert_not_includes english, "Write the entire answer in Spanish."
    assert_includes english, "Follow that objective."
  end

  test "a technical fault defaults to advance_fault and a nameplate question does not" do
    fault = unknown_context("Se quedó entre pisos, ¿qué hago?")
    assert_equal "advance_fault", fault.turn_objective
    assert_equal "default_fault_progress", fault.turn_objective_basis
    assert_includes fault.to_s, Rag::CompanionGuidanceContext::OBJECTIVE_LINES.fetch("advance_fault")
    assert_not_includes fault.to_s, "Ask them to read the nameplate"

    identify = unknown_context("¿Qué puedo mirar para identificar el equipo?")
    assert_equal "resolve_identity", identify.turn_objective
    assert_equal "explicit_identification_request", identify.turn_objective_basis
    assert_includes identify.to_s, "Ask them to read the nameplate and report the manufacturer and model"
    assert_includes identify.to_s, "Do not suggest either."
    assert_includes identify.to_s, "Do not confirm a proposed identity without evidence."

    confirm = unknown_context("¿Mi equipo es un ZEPHYR QX-77?")
    assert_equal "resolve_identity", confirm.turn_objective
    assert_equal "explicit_identity_confirmation_request", confirm.turn_objective_basis

    named = unknown_context("Is this a ZEPHYR?")
    assert_equal "resolve_identity", named.turn_objective
    assert_equal "explicit_identity_confirmation_request", named.turn_objective_basis
  end

  test "a generic part question is not identity resolution" do
    sensor = unknown_context("¿Qué modelo de sensor necesito?")
    contactor = unknown_context("¿Qué marca de contactor recomiendas?")

    assert_equal "advance_fault", sensor.turn_objective
    assert_equal "default_fault_progress", sensor.turn_objective_basis
    assert_equal "advance_fault", contactor.turn_objective
    assert_not_includes sensor.to_s, "Ask them to read the nameplate"
  end

  test "a mixed identity and procedure question resolves identity and does not teach the reset" do
    mixed = unknown_context("¿Es un Orona? ¿Cómo lo reseteo?")

    assert_equal "resolve_identity", mixed.turn_objective
    assert_equal "explicit_identity_confirmation_request", mixed.turn_objective_basis
    prompt = mixed.to_s
    assert_includes prompt, "Current objective: resolve equipment identity."
    assert_includes prompt, "do not give those steps"
    assert_includes prompt, "Ask them to read the nameplate and report the manufacturer and model"
  end

  test "manual reset and value requests stay on advance_fault" do
    questions = [
      "Dame el procedimiento de rescate numerado",
      "No sé qué maniobra es, ¿cómo la reseteo?",
      "¿Qué tensión debe haber en la borna de seguridad?",
      "What's the procedure to bring the car down?",
      "Tengo el manual seleccionado. Dame el procedimiento de rescate."
    ]

    questions.each do |question|
      context = unknown_context(question)
      assert_equal "advance_fault", context.turn_objective, question
      assert_equal "default_fault_progress", context.turn_objective_basis, question
      assert_not_includes context.to_s, "Ask them to read the nameplate", question
      assert_not_includes context.to_s, "anyone inside", question
    end
  end

  test "a code meaning or an unconfirmed manual makes identity the objective" do
    code = unknown_context("El display muestra Q-731, ¿qué significa?")
    spanish = unknown_context("¿Qué dice el manual ZEPHYR QX-77 en la página 12? Puede no ser mi equipo.")
    english = unknown_context("What does the ZEPHYR QX-77 manual say? It may not apply to this equipment.")

    [ code, spanish, english ].each do |context|
      assert_equal "resolve_identity", context.turn_objective
      assert_equal "documentation_applicability", context.turn_objective_basis
      assert_includes context.to_s, "Ask them to read the nameplate and report the manufacturer and model"
    end
  end

  test "manual titles do not force an identity question" do
    same_equipment = unknown_context(
      "la puerta no cierra",
      manuals: [ "Elemont MH operador, p. 1", "Elemont MH controlador, p. 2" ]
    )
    titles_only = unknown_context(
      "la puerta no cierra",
      manuals: [ "Elemont MH, p. 1", "Manual CEA15, p. 2" ]
    )
    pages = unknown_context(
      "la puerta no cierra",
      manuals: [ "Elemont MH, p. 1", "Elemont MH, p. 4" ]
    )

    [ same_equipment, titles_only, pages ].each do |context|
      assert_equal "advance_fault", context.turn_objective
      assert_equal "default_fault_progress", context.turn_objective_basis
      assert_not_includes context.to_s, "Ask them to read the nameplate"
    end
  end

  test "an oversized goal is omitted whole and the objective line stays" do
    context = unknown_context(
      "la puerta no cierra",
      session_context: "## Active Field Problem\nGoal: #{"detalle " * 800}\n"
    )
    prompt = context.to_s

    assert context.context_truncated?
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
    assert prompt.start_with?("# FIELD COMPANION\n#{Rag::CompanionGuidanceContext::OBJECTIVE_LINES.fetch("advance_fault")}")
    assert_not_includes prompt, "detalle"
    assert_not_includes prompt, "Goal:"
    assert_includes prompt, "Question: la puerta no cierra"
    assert_includes prompt, Rag::CompanionGuidanceContext::HYPOTHESIS_RULE
  end

  test "a question that states an equipment condition uses the symptom branch" do
    stuck = unknown_context("Se quedó entre pisos, ¿qué hago?")
    noise = unknown_context("Hace un ruido al arrancar. ¿Qué puedo observar sin intervenir?")

    assert_equal true, stuck.reported_state_present
    assert_equal true, noise.reported_state_present
    [ stuck, noise ].each do |context|
      prompt = context.to_s
      assert_includes prompt, "tied to the reported symptom"
      assert_includes prompt, Rag::CompanionGuidanceContext::OBJECTIVE_LINES.fetch("advance_fault")
      assert_not_includes prompt, Rag::CompanionGuidanceContext::NO_STATE_OBJECTIVE
    end
  end

  test "a procedure reset or value request with no state uses the task branch" do
    questions = [
      "Dame el procedimiento de rescate numerado",
      "No sé qué maniobra es, ¿cómo la reseteo?",
      "¿Qué tensión debe haber en la borna de seguridad?"
    ]

    questions.each do |question|
      context = unknown_context(question)
      prompt = context.to_s
      assert_equal false, context.reported_state_present, question
      assert_equal "advance_fault", context.turn_objective, question
      assert_includes prompt, Rag::CompanionGuidanceContext::NO_STATE_OBJECTIVE, question
      assert_not_includes prompt, "reported fault", question
      assert_not_includes prompt, "reported symptom", question
      assert_includes prompt, "Do not ask them to describe the fault", question
      assert_includes prompt, "restate the symptom", question
      assert_includes prompt, "distinguishes causes", question
      assert_includes prompt, "interprets a result already reported", question
      assert_includes prompt, "next step of this request", question
      assert_includes prompt, "Not a checklist.", question
      assert_includes prompt, "Do not ask equipment identity by routine.", question
      assert_not_includes prompt, "anyone inside", question
      assert_includes prompt, "Passive means a state that already exists.", question
      assert_includes prompt, "Do not have them press, activate, call, send, move", question
      assert_includes prompt, "Say it is not confirmed", question
    end
  end

  test "an active problem or a visual observation is state and a request-only prior turn is not" do
    problem = unknown_context(
      "¿Qué reviso?",
      session_context: "## Active Field Problem\nGoal: la puerta no termina de cerrar\nManufacturer: Elemont (catalog)\n"
    )
    visual = unknown_context(
      "Dame el procedimiento",
      session_context: "## Photo Evidence (this turn)\n- Condition: abierta\n"
    )
    request = unknown_context(
      "¿Y ahora?",
      session_context: "## Recent Conversation\nUser: Dame el procedimiento\nAssistant: Sigo.\n"
    )

    assert_equal true, problem.reported_state_present
    assert_includes problem.to_s, "tied to the reported symptom"
    assert_equal true, visual.reported_state_present
    assert_equal false, request.reported_state_present
    assert_includes request.to_s, Rag::CompanionGuidanceContext::NO_STATE_OBJECTIVE
    assert_nil unknown_context("la puerta no cierra", mode: :known).reported_state_present
  end

  test "resolve identity keeps the nameplate question" do
    identify = unknown_context("¿Qué puedo mirar para identificar el equipo?")
    prompt = identify.to_s

    assert_equal "resolve_identity", identify.turn_objective
    assert_equal false, identify.reported_state_present
    assert_includes prompt, "Current objective: resolve equipment identity."
    assert_includes prompt, "Ask them to read the nameplate and report the manufacturer and model"
    assert_not_includes prompt, Rag::CompanionGuidanceContext::NO_STATE_OBJECTIVE
  end

  test "a long question in a representative context keeps the episode inside the budget" do
    manuals = [
      "Manual largo de referencia uno, p. 12",
      "Manual largo de referencia dos, p. 4",
      "Manual largo de referencia tres, p. 8"
    ]
    session = <<~TEXT
      ## Active Field Problem
      Goal: #{'la puerta no cierra ' * 12}
      ## Photo Evidence (this turn)
      - Component: puerta
      - Condition: abierta
      ## Recent Conversation
      User: #{'ruido al arrancar ' * 8}
      Assistant: Sigo con la puerta.
      User: #{'sigue el ruido ' * 8}
    TEXT
    context = Rag::CompanionGuidanceContext.build(
      question: "Se quedó entre pisos, ¿qué hago? #{'detalle ' * 40}",
      identity: nil,
      session_context: session,
      labels: [],
      locale: :es,
      mode: :unknown,
      manuals: manuals
    )
    prompt = context.to_s

    assert_equal "advance_fault", context.turn_objective
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
    assert_equal true, context.reported_state_present
    line = Rag::CompanionGuidanceContext::OBJECTIVE_LINES.fetch(context.turn_objective)
    assert prompt.start_with?("# FIELD COMPANION\n#{line}")
    question = prompt.lines.find { |row| row.start_with?("Question:") }
    assert_equal "Question: Se quedó entre pisos, ¿qué hago? #{'detalle ' * 40}".rstrip, question.strip
    assert_includes prompt, "Goal: #{'la puerta no cierra ' * 12}".strip
    assert_includes prompt, "Condition: abierta"
    assert_includes prompt, "Component: puerta"
    assert_not_includes prompt, "Manual largo de referencia"
  end

  test "session 196 turn 14 keeps the episode inside the budget" do
    context = unknown_context(
      "¿Y ahora?",
      session_context: session_196_turn_14_context,
      manuals: session_196_manuals
    )
    prompt = context.to_s
    correction = "Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1."

    assert context.context_truncated?
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
    assert_includes prompt, "Question: ¿Y ahora?"
    assert_includes prompt, correction
    assert_includes prompt, "no hay personas dentro"
    assert_includes prompt, "El LED 7 está apagado"
    assert_includes prompt, Rag::CompanionGuidanceContext::HYPOTHESIS_RULE
    assert_includes prompt, "Do not teach retrieved manuals. Those contents are not in this prompt."
    assert_includes prompt, "Do not invent electrical values, terminals, fault-code meanings"
    assert_includes prompt, "Fault code: 18 (technician)"
    assert_includes prompt, "Not current: fault code 8"
    assert_not prompt.match?(/^Fault code: 8\b/)
    assert_includes prompt, "Obs: La cabina está detenida cerca de planta 1;"
    assert_not_includes prompt, "Sigue igual."
    assert_not_includes prompt, "Retrieved manuals"
    session_196_manuals.each { |name| assert_not_includes prompt, name }
  end

  test "a corrected plant stays current and a rejected fault code stays rejected" do
    session = session_196_turn_14_context.sub(
      "La cabina está detenida cerca de planta 1",
      "La cabina está detenida cerca de planta 2"
    )
    prompt = unknown_context(
      "¿Y ahora?",
      session_context: session,
      manuals: session_196_manuals
    ).to_s
    observation = prompt.lines.grep(/\AObs:/).join

    assert_includes observation, "cerca de planta 2"
    assert_not_includes observation, "planta 1"
    assert_includes prompt, "Fault code: 18 (technician)"
    assert_includes prompt, "Not current: fault code 8"
    assert_not prompt.match?(/^Fault code: 8\b/)
    assert_includes prompt, "no de planta 1."
    assert_includes prompt, Rag::CompanionGuidanceContext::HYPOTHESIS_RULE
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
  end

  test "known and english guidance use the same unit budget" do
    labels = session_196_manuals.map { |name| "REFERENCE ONLY — OTHER EQUIPMENT: #{name}" }
    known = Rag::CompanionGuidanceContext.build(
      question: "¿Y ahora?",
      identity: nil,
      session_context: session_196_turn_14_context,
      labels: labels,
      locale: :es,
      mode: :known
    )
    known_prompt = known.to_s

    assert_not known.context_truncated?
    assert_includes known_prompt, "Sigue igual."
    assert_includes known_prompt, "manual-cea15p, p. 84.0"
    assert_includes known_prompt, "Follow-up: yes."
    assert_includes known_prompt, Rag::CompanionGuidanceContext::HYPOTHESIS_RULE
    assert_includes known_prompt, "There is no compatible manufacturer procedure available."
    assert_operator known_prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS

    english = unknown_context(
      "¿Y ahora?",
      session_context: session_196_turn_14_context,
      manuals: session_196_manuals,
      locale: :en
    )
    spanish = unknown_context(
      "¿Y ahora?",
      session_context: session_196_turn_14_context,
      manuals: session_196_manuals
    )

    assert_includes english.to_s, "Write the entire answer in English."
    assert_not_includes english.to_s, "Write the entire answer in Spanish."
    assert_equal spanish.to_s.length, english.to_s.length
    assert_equal spanish.context_truncated?, english.context_truncated?
    assert_includes english.to_s, "Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1."
    assert_not_includes english.to_s, "Retrieved manuals"
  end

  test "a short prompt keeps manuals, history, and the hypothesis rule" do
    session = <<~TEXT
      ## Active Field Problem
      Goal: la puerta no cierra
      ## Recent Conversation
      User: Ya comprobé la guía.
      Assistant: Sigo.
    TEXT
    context = unknown_context("¿Qué reviso?", session_context: session, manuals: [ "Elemont MH, p. 1" ])
    prompt = context.to_s

    assert_not context.context_truncated?
    assert_includes prompt, "Ya comprobé la guía."
    assert_includes prompt, "Elemont MH, p. 1"
    assert_includes prompt, "Retrieved manuals, not confirmed for this equipment."
    assert_includes prompt, "Follow-up: yes."
    assert_includes prompt, "Question: ¿Qué reviso?"
    assert_includes prompt, "Goal: la puerta no cierra"
    assert_includes prompt, Rag::CompanionGuidanceContext::HYPOTHESIS_RULE
    assert_operator prompt.length, :<, Rag::CompanionGuidanceContext::MAX_CHARS
  end

  test "an empty search keeps the episode observations" do
    context = Rag::CompanionGuidanceContext.build(
      question: "¿Y ahora?",
      identity: nil,
      session_context: session_196_turn_14_context,
      labels: [],
      locale: :es,
      mode: :unknown,
      manuals: session_196_manuals,
      empty_retrieval: true
    )
    prompt = context.to_s

    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
    assert_includes prompt, "Obs:"
    assert_includes prompt, "no hay personas dentro"
    assert_includes prompt, "El LED 7 está apagado"
    assert_includes prompt, "The search returned no documentation."
    assert_includes prompt, "Do not say the manual does not exist."
    assert_includes prompt, "Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1."
    assert_includes prompt, "Question: ¿Y ahora?"
    assert_includes prompt, "Goal: la puerta 1 no termina de cerrar el imán no magnetiza"
    assert_includes prompt, "Fault code: 18 (technician)"
    assert_includes prompt, "Not current: fault code 8"
    assert_not prompt.match?(/^Fault code: 8\b/)
  end

  test "a long question keeps the episode instead of only the follow-up" do
    prompt = unknown_context(
      long_field_question,
      session_context: session_196_turn_14_context,
      manuals: session_196_manuals
    ).to_s

    assert_continuity prompt, question: long_field_question
    assert_includes prompt, "Obs:"
    assert_includes prompt, "El LED 7 está apagado"
    assert_includes prompt, "no veo una obstrucción"
  end

  test "an empty pinned search keeps the episode checks" do
    prompt = Rag::CompanionGuidanceContext.build(
      question: "¿Y ahora?",
      identity: nil,
      session_context: session_196_turn_14_context,
      labels: [],
      locale: :es,
      mode: :unknown,
      manuals: session_196_manuals,
      empty_retrieval: true,
      pinned_focus_empty: true
    ).to_s

    assert_continuity prompt, question: "¿Y ahora?"
    assert_includes prompt, "The pinned focus returned no evidence. Do not release the pin."
    assert_includes prompt, "no hay personas dentro"
    assert_includes prompt, "se oye un clic"
  end

  test "a correction outside the recent window replaces a redundant echo" do
    correction = "Corrijo algo de antes: la cabina está en planta 4, no en planta 3."
    session = <<~TEXT
      ## Active Field Problem
      Goal: la puerta no termina de cerrar
      Fault code: 41 (technician)
      ## Recent Conversation
      User: #{correction}
      Assistant: Sigo.
      User: la hoja vuelve a abrir al llegar al marco
      Assistant: Sigo.
      User: Sigue igual.
    TEXT
    prompt = unknown_context("¿Qué miro ahora?", session_context: session).to_s

    assert_includes prompt, correction
    assert_includes prompt, "la hoja vuelve a abrir al llegar al marco"
    assert_not_includes prompt, "Sigue igual."
  end

  test "a long correction stays whole past the old turn limit" do
    correction = long_correction
    session = <<~TEXT
      ## Active Field Problem
      Goal: la puerta no termina de cerrar
      Fault code: 41 (technician)
      Identifiers: Nortec QX-4
      Obs: la hoja llega al marco y vuelve a abrir; la guía no tiene una obstrucción
      Not current: fault code 7
      ## Recent Conversation
      User: Sigue igual.
      Assistant: Sigo con la puerta.
      User: #{correction}
    TEXT
    prompt = unknown_context("¿Qué miro ahora?", session_context: session, manuals: [ "Otro manual, p. 3" ]).to_s

    assert_operator correction.length, :>, Rag::CompanionGuidanceContext::TURN_CHARS
    assert_includes prompt, correction
    assert_not prompt.include?(correction[0, Rag::CompanionGuidanceContext::TURN_CHARS] + "\n")
    assert_includes prompt, "Goal: la puerta no termina de cerrar"
    assert_includes prompt, "Fault code: 41 (technician)"
    assert_includes prompt, "Nortec QX-4"
    assert_includes prompt, "Not current: fault code 7"
    assert_includes prompt, "la guía no tiene una obstrucción"
    assert_not prompt.match?(/^Fault code: 7\b/)
  end

  test "a long correction on a generic empty search keeps the goal" do
    correction = long_correction
    session = generic_episode_context.sub(
      "Corrijo algo de antes: la cabina está detenida cerca de planta 4, no de planta 3.",
      correction
    )
    prompt = Rag::CompanionGuidanceContext.build(
      question: long_field_question,
      identity: nil,
      session_context: session,
      labels: [],
      locale: :es,
      mode: :unknown,
      manuals: [ "Manual ajeno, p. 9", "Otro plano, p. 2" ],
      empty_retrieval: true
    ).to_s

    assert_operator correction.length, :>, Rag::CompanionGuidanceContext::TURN_CHARS
    assert_includes prompt, "Question: #{long_field_question}"
    assert_includes prompt, "Goal: la puerta del montacargas no termina de cerrar"
    assert_includes prompt, "Manufacturer: Nortec (catalog)"
    assert_includes prompt, "Identifiers: Nortec QX-4"
    assert_includes prompt, "Fault code: 41 (technician)"
    assert_includes prompt, "Not current: fault code 7"
    assert_includes prompt, correction
    assert_includes prompt, "cerca de planta 4"
    assert_includes prompt, "no hay personas dentro"
    assert_includes prompt, "la hoja llega al marco y vuelve a abrir"
    assert_includes prompt, "la guía no tiene una obstrucción"
    assert_includes prompt, "el indicador 2 está encendido fijo"
    assert_includes prompt, "The search returned no documentation."
    assert_includes prompt, "Do not say the manual does not exist."
    assert_includes prompt, Rag::CompanionGuidanceContext::QUESTION_RULE
    assert_includes prompt, Rag::CompanionGuidanceContext::HYPOTHESIS_RULE
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
    assert_not prompt.match?(/^Fault code: 7\b/)
  end

  test "a pinned generic empty search keeps the goal with a long correction" do
    correction = long_correction
    session = generic_episode_context.sub(
      "Corrijo algo de antes: la cabina está detenida cerca de planta 4, no de planta 3.",
      correction
    )
    prompt = Rag::CompanionGuidanceContext.build(
      question: long_field_question,
      identity: nil,
      session_context: session,
      labels: [],
      locale: :es,
      mode: :unknown,
      manuals: [ "Manual ajeno, p. 9", "Otro plano, p. 2" ],
      empty_retrieval: true,
      pinned_focus_empty: true
    ).to_s

    assert_includes prompt, "Question: #{long_field_question}"
    assert_includes prompt, "Goal: la puerta del montacargas no termina de cerrar"
    assert_includes prompt, "Manufacturer: Nortec (catalog)"
    assert_includes prompt, "Identifiers: Nortec QX-4"
    assert_includes prompt, "Fault code: 41 (technician)"
    assert_includes prompt, "Not current: fault code 7"
    assert_includes prompt, correction
    assert_includes prompt, "cerca de planta 4"
    assert_includes prompt, "no hay personas dentro"
    assert_includes prompt, "la hoja llega al marco y vuelve a abrir"
    assert_includes prompt, "la guía no tiene una obstrucción"
    assert_includes prompt, "el indicador 2 está encendido fijo"
    assert_includes prompt, "The search returned no documentation."
    assert_includes prompt, "Do not say the manual does not exist."
    assert_includes prompt, "The pinned focus returned no evidence. Do not release the pin."
    assert_includes prompt, Rag::CompanionGuidanceContext::QUESTION_RULE
    assert_includes prompt, Rag::CompanionGuidanceContext::HYPOTHESIS_RULE
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
    assert_not prompt.match?(/^Fault code: 7\b/)
  end

  test "a generic episode keeps its checks when the question is long and the search is empty" do
    prompt = Rag::CompanionGuidanceContext.build(
      question: long_field_question,
      identity: nil,
      session_context: generic_episode_context,
      labels: [],
      locale: :es,
      mode: :unknown,
      manuals: [ "Manual ajeno, p. 9", "Otro plano, p. 2" ],
      empty_retrieval: true
    ).to_s

    assert_includes prompt, "Question: #{long_field_question}"
    assert_includes prompt, "Goal: la puerta del montacargas no termina de cerrar"
    assert_includes prompt, "Manufacturer: Nortec (catalog)"
    assert_includes prompt, "Fault code: 41 (technician)"
    assert_includes prompt, "Not current: fault code 7"
    assert_includes prompt, "cerca de planta 4"
    assert_not prompt.lines.grep(/\AObs:/).join.include?("planta 3")
    assert_includes prompt, "no de planta 3."
    assert_includes prompt, "el indicador 2 está encendido fijo"
    assert_includes prompt, "The search returned no documentation."
    assert_includes prompt, Rag::CompanionGuidanceContext::HYPOTHESIS_RULE
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
    assert_not prompt.match?(/^Fault code: 7\b/)
  end

  test "known guidance keeps its instruction and does not take the unknown observation rule" do
    prompt = Rag::CompanionGuidanceContext.build(
      question: "la puerta no cierra",
      identity: nil,
      session_context: "",
      labels: [],
      locale: :es
    ).to_s

    assert_includes prompt, "There is no compatible manufacturer procedure available."
    assert_includes prompt, "One main question"
    assert_not_includes prompt, "The equipment identity is not confirmed."
    assert_not_includes prompt, "elevator field service"
    assert_not_includes prompt, "already report an action as done"
    assert_not_includes prompt, "Current objective:"
    assert_not_includes prompt, "SI-2"
    assert_not_includes prompt, "XQ7"
  end

  test "unknown guidance keeps a catalog manufacturer and still says identity is not confirmed" do
    session = <<~TEXT
      ## Active Field Problem
      Goal: la puerta 1 no termina de cerrar el imán no magnetiza
      Manufacturer: Elemont (catalog)
      Identifiers: Elemont MH, CEA15
    TEXT
    prompt = unknown_context(
      "Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?",
      session_context: session
    ).to_s

    assert_includes prompt, "Manufacturer: Elemont (catalog)"
    assert_includes prompt, "The equipment identity is not confirmed."
    assert_not_includes prompt, "There is no compatible manufacturer procedure available."
  end

  def unknown_prompt(question:, session_context:, locale:)
    unknown_context(question, session_context: session_context, locale: locale).to_s
  end

  def unknown_context(question, session_context: "", locale: :es, mode: :unknown, manuals: nil)
    Rag::CompanionGuidanceContext.build(
      question: question,
      identity: nil,
      session_context: session_context,
      labels: [],
      locale: locale,
      mode: mode,
      manuals: manuals
    )
  end

  def assert_continuity(prompt, question:)
    assert_includes prompt, "Question: #{question}"
    assert_includes prompt, "Goal: la puerta 1 no termina de cerrar el imán no magnetiza"
    assert_includes prompt, "Fault code: 18 (technician)"
    assert_includes prompt, "Identifiers: Elemont MH, CEA15"
    assert_includes prompt, "Not current: fault code 8"
    assert_includes prompt, "Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1."
    assert_includes prompt, Rag::CompanionGuidanceContext::HYPOTHESIS_RULE
    assert_not prompt.match?(/^Fault code: 8\b/)
    assert_operator prompt.length, :<=, Rag::CompanionGuidanceContext::MAX_CHARS
  end

  def long_field_question
    text = "Quiero la siguiente comprobación segura de esta misma falla, sin desarmar, sin medir y sin un procedimiento del fabricante, usando la cabina, el marco, el display y lo ya comprobado."
    text += " Sigo en el mismo caso." while text.length < 380
    text
  end

  def long_correction
    "Corrijo algo de antes: la cabina no está detenida cerca de la planta baja del sótano de servicio, está detenida cerca de la planta de acceso del vestíbulo principal, y el indicador no está apagado sino encendido fijo."
  end

  def generic_episode_context
    <<~TEXT
      ## Active Field Problem
      Goal: la puerta del montacargas no termina de cerrar
      Manufacturer: Nortec (catalog)
      Fault code: 41 (technician)
      Identifiers: Nortec QX-4
      Obs: la cabina está detenida cerca de planta 4; no hay personas dentro; la hoja llega al marco y vuelve a abrir; la guía no tiene una obstrucción; el indicador 2 está encendido fijo
      Not current: fault code 7
      ## Recent Conversation
      User: Sigue igual.
      Assistant: Sigo con la puerta.
      User: Corrijo algo de antes: la cabina está detenida cerca de planta 4, no de planta 3.
    TEXT
  end

  def session_196_manuals
    [ "manual-cea15p, p. 84.0", "manual-cea51fb-das, p. 82.0", "manual-cea15p, p. 65.0" ]
  end

  def session_196_turn_14_context
    <<~TEXT
      ## Active Field Problem
      Goal: la puerta 1 no termina de cerrar el imán no magnetiza
      Fault code: 18 (technician)
      Identifiers: Elemont MH, CEA15
      Obs: La cabina está detenida cerca de planta 1; no hay personas dentro; La puerta llega al marco, pero vuelve a abrir; no veo una obstrucción; El LED 7 está apagado; Al pedir cierre se oye un clic, pero no termina de cerrar; Sigue el clic y la puerta no termina de cerrar
      Not current: fault code 8
      Not a manual. Procedures, values, terminals, and code meanings come from retrieved evidence. Ignore for other equipment.
      ## Recent Conversation
      User: Sigue igual.
      Assistant: Escucha el sonido del imán cuando la puerta llega al marco.
      User: Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1.
    TEXT
  end

  def context_for_unknown_fixture(session_context)
    Rag::CompanionGuidanceContext.build(
      question: "¿Qué reviso?",
      identity: nil,
      session_context: session_context,
      labels: [],
      locale: :es,
      mode: :unknown,
      manuals: [ "Elemont Montacargas Hidraulico Modelo MH, p. 1" ]
    )
  end
end
