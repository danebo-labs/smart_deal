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
      "Looks like a uP-900."
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
  end

  test "identity assertion outranks a procedure in the same answer" do
    answer = "Este equipo es uP-900. Envíalo al piso inferior."
    assert_equal :identity_assertion, classify(answer)
  end

  test "an empty retrieval does not classify the answer" do
    assert_nil Rag::DocumentIdentityScope.unconfirmed_applicability_violation(
      "Envíalo al piso inferior.", "Envíalo al piso inferior.", [], "que hago"
    )
  end

  private

  def classify(answer, chunks: [ @up ], question: "que hago")
    Rag::DocumentIdentityScope.unconfirmed_applicability_violation(answer, answer, chunks, question)
  end

  def basis(answer, chunks: [ @up ], question: "que hago")
    Rag::DocumentIdentityScope.unconfirmed_applicability_basis(answer, answer, chunks, question)
  end
end
