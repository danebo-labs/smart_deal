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
    assert_not context_for_unknown_fixture(session_context).context_truncated?
    assert_includes prompt, "does not select the next objective"
    assert_includes prompt, "elevator field service"
    assert_includes prompt, "in the same sentence"
    assert_includes prompt, "One main question"
    assert_includes prompt, "Do not make a questionnaire."
    assert_includes prompt, "Do not instruct an operation that changes equipment state."
    assert_includes prompt, "Do not ask which equipment this is unless identity is the blocker."
    assert_includes prompt, "already report an action as done"
    assert_includes prompt, "Do not stop at the refusal"
    assert_includes prompt, "read the nameplate and report manufacturer and model in one sentence"
    assert_includes prompt, "without suggesting either"
    assert_includes prompt, "Do not confirm a proposed identity."
    assert_includes prompt, "Do not print DATA_NOT_AVAILABLE."
    assert_includes prompt, "Do not cite manuals with [n]."
    assert_includes prompt, "Write the entire answer in Spanish."
    assert_not_includes prompt, "SI-2"
    assert_not_includes prompt, "XQ7"
    assert_not_includes prompt, "Enviar la cabina"
    assert_not_includes prompt, "Procedimiento de rescate"
  end

  test "unknown guidance keeps the decision policy inside the prompt budget" do
    prompt = unknown_prompt(question: "", session_context: "", locale: :es)
    instruction = prompt.sub(/\n\nFollow-up: no\.\z/, "")

    assert_operator instruction.length, :<, 1700
    assert_includes prompt, "Write the entire answer in Spanish."
    english = unknown_prompt(question: "the door will not close", session_context: "", locale: :en)
    assert_includes english, "Write the entire answer in English."
    assert_not_includes english, "Write the entire answer in Spanish."
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
    assert_not_includes prompt, "does not select the next objective"
    assert_not_includes prompt, "SI-2"
    assert_not_includes prompt, "XQ7"
  end

  def unknown_prompt(question:, session_context:, locale:)
    Rag::CompanionGuidanceContext.build(
      question: question,
      identity: nil,
      session_context: session_context,
      labels: [],
      locale: locale,
      mode: :unknown
    ).to_s
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
