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
end
