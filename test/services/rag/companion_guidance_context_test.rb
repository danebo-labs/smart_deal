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
    assert_includes prompt, "Ask for one safe look, read, or listen check tied to the reported symptom."
    assert_includes prompt, "in the same sentence"
    assert_includes prompt, "One main question"
    assert_includes prompt, "Do not make a questionnaire."
    assert_includes prompt, "do not reply by only asking which equipment this is"
    assert_includes prompt, "already report an action as done"
    assert_includes prompt, "Do not stop at the refusal"
    assert_includes prompt, "Do not choose the nameplate or the equipment identity as the main question."
    assert_not_includes prompt, "If the missing fact is which equipment this is, ask them to read the nameplate"
    assert_not_includes prompt, "Ask them to read the nameplate"
    assert_includes prompt, "You may observe, interpret, and hypothesize."
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

  test "the objective line survives context truncation" do
    context = unknown_context(
      "la puerta no cierra",
      session_context: "## Active Field Problem\nGoal: #{"detalle " * 800}\n"
    )
    prompt = context.to_s

    assert context.context_truncated?
    assert_equal Rag::CompanionGuidanceContext::MAX_CHARS, prompt.length
    assert prompt.start_with?("# FIELD COMPANION\n#{Rag::CompanionGuidanceContext::OBJECTIVE_LINES.fetch("advance_fault")}")
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

  test "a representative context stays inside the character budget and truncation keeps the head" do
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
    if context.context_truncated?
      assert_equal Rag::CompanionGuidanceContext::MAX_CHARS, prompt.length
      line = Rag::CompanionGuidanceContext::OBJECTIVE_LINES.fetch(context.turn_objective)
      assert prompt.start_with?("# FIELD COMPANION\n#{line}")
    else
      assert_includes prompt, "Se quedó entre pisos"
      assert_includes prompt, "Follow-up:"
    end
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
