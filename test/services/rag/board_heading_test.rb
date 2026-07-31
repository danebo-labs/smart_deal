# frozen_string_literal: true

require "test_helper"

class Rag::BoardHeadingTest < ActiveSupport::TestCase
  test "label keeps the board name and drops the descriptive tail" do
    assert_equal "ARCA III",
                 Rag::BoardHeading.label("## S4 — SAFETY SYSTEM: ARCA III — Diagrama de Series")
    assert_equal "CARLOS SILVA TPR50",
                 Rag::BoardHeading.label("## S7 — DIAGRAM: CARLOS SILVA TPR50 — Cadena de Seguridades")
    assert_equal "CTA – M8PC (ELÉCTRICO Y HIDRÁULICO)",
                 Rag::BoardHeading.label("## S7 — DIAGRAM: CTA – M8PC (ELÉCTRICO Y HIDRÁULICO) / BORNAS CARRIL")
    assert_equal "EM 4000 V1",
                 Rag::BoardHeading.label("## EM 4000 V1\nCadena de seguridades ALTIUS conectada en serie.")
  end

  test "label refuses a placeholder heading and a body without one" do
    assert_nil Rag::BoardHeading.label("## PIPELINE_INJECTED")
    assert_nil Rag::BoardHeading.label("LED SPM | SERIE DE PUERTAS")
    assert_nil Rag::BoardHeading.label(nil)
  end

  test "a question that names the board is recognized through the descriptive prose" do
    assert Rag::BoardHeading.mentioned?(
      "ARCA II Safety Chain & Connector Layout",
      "En la placa ARCA II, ¿qué serie indica el LED P32?"
    )
    assert Rag::BoardHeading.mentioned?(
      "Tabla de LEDs de la cadena serie — MICONIC LX",
      "En la placa MICONIC LX de Schindler, lista los LEDs T1 a T5 y la serie que indica cada uno."
    )
    assert Rag::BoardHeading.mentioned?(
      "TWISTER TW – ELECTRICO - EMBARBA",
      "Estoy con una Twister TW de Embarba eléctrica y sospecho de la serie de puertas. " \
      "¿Qué LED de la placa me lo confirma?"
    )
  end

  test "gender and plural variants of a board word still match" do
    assert Rag::BoardHeading.mentioned?(
      "ARCA BASICO",
      "En la placa ARCA básica, ¿qué serie indica el LED P32?"
    )
  end

  test "a question with no board named matches no board" do
    [
      "TWISTER TW - INAPELSA",
      "DELTA +",
      "CARLOS SILVA TPR50"
    ].each do |heading|
      assert_not Rag::BoardHeading.mentioned?(heading, "¿A qué serie corresponde el LED SPM?"),
                 "expected #{heading.inspect} not to be named by the SPM question"
    end

    assert_not Rag::BoardHeading.mentioned?(
      "LEVEL CONTROL 1B – ELECTRICO - PREMONTADA",
      "¿Qué serie indica el LED DL2?"
    )
    assert_not Rag::BoardHeading.mentioned?("KDT 11", "¿Qué serie indica el LED DL2?")
  end

  test "a partially named board is not a named board" do
    assert_not Rag::BoardHeading.mentioned?(
      "MICONIC BX",
      "En la placa MICONIC LX de Schindler, lista los LEDs T1 a T5."
    )
    assert_not Rag::BoardHeading.mentioned?("ARCA III", "En la placa ARCA II, ¿qué indica el LED P32?")
    assert_not Rag::BoardHeading.mentioned?("ARCA II", "")
  end
end
