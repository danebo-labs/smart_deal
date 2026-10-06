# frozen_string_literal: true

require "test_helper"

class Rag::UnconfirmedApplicabilityTest < ActiveSupport::TestCase
  setup do
    @up = {
      content: "Q-731 = fallo de puerta. Borne XQ7. Esperar 47 s. Selector SI-2.",
      metadata: {
        "canonical_name" => "Listado uP-900",
        "section_identity" => "uP-900",
        "page_number" => 12,
        "aliases" => [ "uP-900" ]
      }
    }
    @zephyr = {
      content: "Enviar la cabina al piso inferior. Modo inspección con selector SI-2. Cortar tensión en borne XQ7. Esperar 47 s. Q-731 = fallo de puerta.",
      metadata: {
        "canonical_name" => "ZEPHYR QX-77",
        "page_number" => 12,
        "aliases" => [ "ZEPHYR QX-77" ]
      }
    }
  end

  test "identity assertions are withheld and confirmations stay open" do
    violations = [
      "Tu equipo es uP-900.",
      "Your controller is uP-900.",
      "Esta maniobra es uP-900.",
      "Es un uP-900.",
      "Probablemente el controlador de este ascensor sea uP-900.",
      "Este equipo es uP-900, como se documenta en el manual.",
      "Se trata de un uP-900.",
      "Parece ser un uP-900.",
      "It's a uP-900.",
      "Looks like a uP-900.",
      "Probablemente se trata de un uP-900.",
      "Seguramente es un uP-900.",
      "Por lo que describes, se trata de un uP-900."
    ]
    allowed = [
      "No está confirmado que este equipo sea uP-900.",
      "Confirma si este equipo es uP-900.",
      "En el manual uP-900 se documenta el síntoma."
    ]

    violations.each do |answer|
      assert_equal :identity_assertion, classify(answer), answer
    end
    allowed.each do |answer|
      assert_nil classify(answer), answer
    end
  end

  test "unqualified procedures are procedure applications" do
    [
      "Envíalo al piso inferior.",
      "Envíe la cabina al piso inferior.",
      "Manda la cabina y enviala abajo.",
      "Se debe cortar tensión.",
      "Deberías cortar tensión antes de moverlo.",
      "The next step is to enter inspection.",
      "1. Corte de tensión.\n2. Paso a inspección.",
      "Haz el corte de tensión.",
      "You should reset the board."
    ].each do |answer|
      assert_equal :procedure_application, classify(answer, chunks: [ @zephyr ]), answer
      assert_equal :operation, basis(answer, chunks: [ @zephyr ]), answer
    end
  end

  test "a qualified manual reference in the same paragraph is published" do
    answer = "Según el manual uP-900, p. 12, se indica enviar la cabina al piso inferior. No está confirmado que ese procedimiento aplique a este equipo."
    assert_nil classify(answer)
    assert_includes answer, "p. 12"
  end

  test "a disclaimer in the next sentence of the same paragraph qualifies the operation" do
    answer = "Según el manual uP-900 se indica cortar tensión en el borne. No corresponde a este equipo."
    assert_nil classify(answer)
  end

  test "a leading disclaimer does not qualify a later paragraph" do
    answer = "No está confirmado que este material aplique a este equipo.\n\nEnvíalo al piso inferior."
    assert_equal :procedure_application, classify(answer)
  end

  test "observation and real questions stay open while embedded operations and action requests do not" do
    assert_nil classify("Observa si la puerta abre.")
    assert_nil classify("Observe si hay movimiento incontrolado.")
    assert_nil classify("Anota si la cabina se mueve normalmente.")
    assert_nil classify("Observaciones pasivas.\n\n**No realices:**\n- Ajustes, desconexiones, o acceso a terminales.")
    assert_nil classify(
      "Este es un equipo de plataforma elevadora (tijera), no un ascensor convencional.",
      chunks: [ {
        content: "Plataforma tijera.",
        metadata: { "canonical_name" => "Manual Plataforma Tijera", "aliases" => [ "Manual Plataforma Tijera" ] }
      } ]
    )
    assert_equal :procedure_application, classify("Mueve la cabina al piso inferior.")
    assert_equal :procedure_application, classify("Movimiento de cabina al piso inferior.")
    assert_equal :procedure_application, classify("Haz que se mueva la cabina al piso inferior.")
    assert_nil classify("La cabina se mueve normalmente.")
    assert_equal :procedure_application, classify(<<~TEXT)
      **No realices:**
      - Puentes.

      Pasos de rescate:
      1. Envía la cabina al piso inferior.
    TEXT
    assert_nil classify("Inspeccione visualmente la puerta.")
    assert_nil classify("According to the uP-900 manual, p. 12, send the car down. Applicability is not confirmed.")
    assert_equal :procedure_application, classify("Observa si al cortar tensión el display se apaga.")
    assert_equal :procedure_application, classify("Confirma el puente XQ7-XQ8.")
    assert_nil classify("¿Hubo un corte de luz?")
    assert_equal :procedure_application, classify("¿Puedes resetear la placa?")
    assert_nil classify("No cortar tensión.")
    assert_nil classify("Evita cortar tensión.")
    assert_nil classify("Detén el trabajo y llama al supervisor.")
  end

  test "foreign codes terminals connections and units are applicability violations unless echoed" do
    assert_equal :procedure_application, classify(
      "Q-731 significa fallo de puerta.",
      chunks: [ @zephyr ], question: "el display parpadea"
    )
    assert_equal :value_code, basis(
      "Q-731 significa fallo de puerta.",
      chunks: [ @zephyr ], question: "el display parpadea"
    )
    assert_equal :procedure_application, classify(
      "La espera que figura es 47 s.",
      chunks: [ @zephyr ], question: "no arranca"
    )
    assert_equal :value_code, basis(
      "La espera que figura es 47 s.",
      chunks: [ @zephyr ], question: "no arranca"
    )
    assert_equal :procedure_application, classify(
      "El selector SI-2 activa la inspección.",
      chunks: [ @zephyr ], question: "no arranca"
    )
    assert_nil classify(
      "El display muestra Q-731.",
      chunks: [ @zephyr ], question: "El display muestra Q-731, ¿qué significa?"
    )
    assert_equal :value_code, basis(
      "Q-731 significa fallo de puerta.",
      chunks: [ @zephyr ], question: "El display muestra Q-731, ¿qué significa?"
    )
    assert_equal :value_code, basis(
      "La borna de seguridad es XQ7.",
      chunks: [ @zephyr ], question: "no arranca"
    )
    assert_equal :value_code, basis(
      "Q-731 = fallo de puerta [1]",
      chunks: [ @zephyr ], question: "El display muestra Q-731, ¿qué significa?"
    )
    assert_nil classify(
      "Q-731",
      chunks: [ @zephyr ], question: "El display muestra Q-731, ¿qué significa?"
    )
    assert_nil classify(
      "Según el manual ZEPHYR, Q-731 = fallo de puerta [1]. No está confirmado que aplique a este equipo.",
      chunks: [ @zephyr ], question: "El display muestra Q-731, ¿qué significa?"
    )
  end

  test "symmetric applicability corpus keeps violations and safe references apart" do
    identity_violations = [
      "Este equipo es uP-900.",
      "Tu equipo es uP-900.",
      "Your controller is uP-900.",
      "Probablemente se trata de un uP-900.",
      "Por lo que describes, se trata de un uP-900.",
      "Este equipo es uP-900, como se documenta en el manual."
    ]
    identity_violations << {
      answer: "Based on the display, it is a ZEPHYR QX-77.",
      chunks: [ @zephyr ]
    }
    identity_allowed = [
      "No está confirmado que este equipo sea uP-900.",
      "Confirma si este equipo es uP-900.",
      "En el manual uP-900 se describe el síntoma. No está confirmado que aplique a este equipo.",
      "La página dice que es un indicador y nombra el manual uP-900."
    ]
    operation_violations = [
      "Envía la cabina al piso inferior.",
      "Enviar la cabina al piso inferior.",
      "Movimiento de cabina al piso inferior.",
      "Se debe cortar tensión.",
      "Deberías cortar tensión.",
      "Haz que se mueva la cabina al piso inferior.",
      "1. Envía la cabina al piso inferior.",
      "Movimiento de la cabina al piso inferior.",
      "Pulsa el botón de inspección.",
      "Al pulsar el selector de inspección.",
      "Al pulsar SI-2.",
      "Corta tensión ahora.",
      { answer: "Corta tensión ahora.", question: "Ya corté tensión, ¿y ahora?" },
      { answer: "Cortar tensión ahora.", question: "Ya corté tensión, ¿y ahora?" },
      {
        answer: "Escuche si hay sonidos después de cortar tensión.",
        question: "Se quedó entre pisos, ¿qué hago?"
      }
    ]
    operation_allowed = [
      "La cabina se mueve normalmente.",
      "Observa si la cabina se mueve.",
      "Observa si hay movimiento incontrolado.",
      "Escucha si hay movimiento de la cabina.",
      "Escucha y observa si hay movimiento de la cabina, sonidos anormales o mensajes en la pantalla de control.",
      "Anote cuándo comienza (al pulsar el botón, durante los primeros segundos, al llegar a destino).",
      {
        answer: "Escuche si hay sonidos de funcionamiento o alarmas después de cortar tensión.",
        question: "Ya corté tensión, ¿y ahora?"
      },
      "No realices ajustes ni desconexiones.",
      "Lee la placa y anota el fabricante."
    ]
    value_violations = [
      { answer: "Q-731 = fallo de puerta [1]", question: "El display muestra Q-731, ¿qué significa?" },
      { answer: "Q-731 significa fallo de puerta.", question: "el display parpadea" },
      { answer: "La borna de seguridad es XQ7.", question: "no arranca" },
      { answer: "El selector SI-2 activa la inspección.", question: "no arranca" },
      { answer: "La espera que figura es 47 s.", question: "no arranca" }
    ]
    value_allowed = [
      {
        answer: "El display muestra Q-731.",
        question: "El display muestra Q-731, ¿qué significa?"
      },
      {
        answer: "Según el manual ZEPHYR, Q-731 = fallo de puerta [1]. No está confirmado que aplique a este equipo.",
        question: "El display muestra Q-731, ¿qué significa?"
      },
      {
        answer: "El display muestra Q-731.",
        question: "El display muestra Q-731, ¿qué significa?"
      }
    ]

    identity_violations.each { |row| assert_family(:identity_assertion, row) }
    identity_allowed.each { |row| assert_family(nil, row) }
    operation_violations.each { |row| assert_family(:procedure_application, row, chunks: [ @zephyr ]) }
    operation_allowed.each { |row| assert_family(nil, row, chunks: [ @zephyr ]) }
    value_violations.each { |row| assert_family(:procedure_application, row, chunks: [ @zephyr ]) }
    value_allowed.each { |row| assert_family(nil, row, chunks: [ @zephyr ]) }
  end

  test "identity assertion outranks a procedure in the same answer" do
    answer = "Este equipo es uP-900. Envíalo al piso inferior."
    assert_equal :identity_assertion, classify(answer)
  end

  test "an empty retrieval still detects an unsupported operation" do
    assert_equal :procedure_application, classify("Envíalo al piso inferior.", chunks: [])
    assert_equal :operation, basis("Envíalo al piso inferior.", chunks: [])
    assert_equal :procedure_application, classify(
      "Con tensión cortada, revisa el voltaje en los terminales principales del controlador con un multímetro para confirmar que no hay energía residual.",
      chunks: []
    )
    assert_equal :directed_measurement, basis(
      "Con tensión cortada, revisa el voltaje en los terminales principales del controlador con un multímetro para confirmar que no hay energía residual.",
      chunks: []
    )
  end

  test "an empty retrieval does not run identity or value applicability" do
    assert_nil classify("Este equipo es uP-900.", chunks: [])
    assert_nil classify("Tu equipo es uP-900.", chunks: [])
    assert_nil classify("Q-731 significa fallo de puerta.", chunks: [], question: "el display parpadea")
    assert_nil classify("La espera que figura es 47 s.", chunks: [], question: "no arranca")
    assert_equal :identity_assertion, classify("Este equipo es uP-900.")
    assert_equal :value_code, basis("Q-731 significa fallo de puerta.", question: "el display parpadea")
  end

  test "a reported measurement stays context and a directed measurement does not" do
    reported = [
      "Ya medí 220 V.",
      "El técnico ya midió 220 V en la borna.",
      "Ya revisé el voltaje en los terminales con un multímetro."
    ]
    reported.each do |answer|
      assert_nil classify(answer), answer
      assert_nil classify(answer, chunks: []), answer
    end

    directed = "Revisa el voltaje en los terminales principales del controlador con un multímetro."
    assert_equal :procedure_application, classify(directed)
    assert_equal :directed_measurement, basis(directed)

    repeated = "Ya mediste 220 V. Vuelve a medir el voltaje en los terminales con el multímetro."
    assert_equal :procedure_application, classify(repeated)
    extended = "Ya medí 220 V. Revisa otra vez el voltaje en los terminales con el multímetro."
    assert_equal :directed_measurement, basis(extended)
  end

  test "a directive measurement question does not escape and door contact is not probe placement" do
    assert_equal :directed_measurement, basis("¿Puedes revisar el voltaje en los terminales con un multímetro?")
    assert_equal :directed_measurement, basis("¿Revisas el voltaje en los bornes con un multímetro?")
    assert_nil classify("¿Revisa el contacto de la puerta y dime si cierra?")
    assert_nil classify("Revisa el contacto de puerta.")
    assert_nil classify("Revisa el voltaje.")
    assert_nil classify("Usa un multímetro.")
    assert_nil classify("Hay voltaje en los terminales.")
    assert_nil classify("No revises el voltaje en los terminales con un multímetro.")
  end

  private

  def assert_family(expected, row, chunks: [ @up ])
    answer, question, row_chunks = corpus_row(row, chunks)
    actual = classify(answer, chunks: row_chunks, question: question)
    if expected.nil?
      assert_nil actual, answer
    else
      assert_equal expected, actual, answer
    end
  end

  def corpus_row(row, chunks)
    return [ row, "que hago", chunks ] unless row.is_a?(Hash)

    [ row[:answer], row.fetch(:question, "que hago"), row.fetch(:chunks, chunks) ]
  end

  def classify(answer, chunks: [ @up ], question: "que hago")
    Rag::DocumentIdentityScope.unconfirmed_applicability_violation(answer, answer, chunks, question)
  end

  def basis(answer, chunks: [ @up ], question: "que hago")
    Rag::DocumentIdentityScope.unconfirmed_applicability_basis(answer, answer, chunks, question)
  end
end
