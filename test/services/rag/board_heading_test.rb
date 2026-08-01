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

  test "a parenthetical footnote on the heading does not block a match" do
    assert Rag::BoardHeading.mentioned?(
      "Diagrama de cadena de seguridades ARCA III (Orona PDCM 5124537)",
      "En la placa ARCA básica, ¿qué serie indica el LED P32? ¿Significa lo mismo en ARCA III?"
    )
  end

  test "the parenthetical is kept verbatim in the label a heading returns" do
    assert_equal "Diagrama de cadena de seguridades ARCA III (Orona PDCM 5124537)",
                 Rag::BoardHeading.label(
                   "## S4 — SAFETY SYSTEM: Diagrama de cadena de seguridades ARCA III " \
                   "(Orona PDCM 5124537)"
                 )
  end

  test "section_label extracts the board name a generic table heading hides behind it" do
    content = <<~CONTENT
      **Document:** ALJO Control Level 1B Altius
      **Page:** 62 of 97
      **Section:** S7 — DIAGRAM: ARCA BASICO — Cadena de Seguridades y Conectores Principales

      ## LEDs de Estado — Tabla de Series

      | LED | SERIE |
    CONTENT

    assert_equal "ARCA BASICO", Rag::BoardHeading.section_label(content)
  end

  test "section_label is nil without a Section line or with a blank one" do
    assert_nil Rag::BoardHeading.section_label("## LEDs de Estado — Tabla de Series")
    assert_nil Rag::BoardHeading.section_label(nil)
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

  # H-03: word_match?'s common-prefix allowance for gender/plural spelling
  # ("BASICO"/"básica") also let sibling boards that differ only by a
  # trailing model digit pass as a match, because the shared root
  # ("EDEL-K") alone already clears MIN_COMMON_PREFIX.
  test "sibling boards distinguished only by a trailing digit are not confused" do
    heading = "EDEL-K3 Wiring Overview — Safety & Door Circuit Connections"

    assert_not Rag::BoardHeading.mentioned?(
      heading, "En la EDEL-K2, ¿qué LED indica que los cerrojos están cerrados?"
    )
    assert Rag::BoardHeading.mentioned?(
      heading, "En la EDEL-K3, ¿qué LED indica que los cerrojos están cerrados?"
    )
  end

  test "a partially named board is not a named board" do
    assert_not Rag::BoardHeading.mentioned?(
      "MICONIC BX",
      "En la placa MICONIC LX de Schindler, lista los LEDs T1 a T5."
    )
    assert_not Rag::BoardHeading.mentioned?("ARCA III", "En la placa ARCA II, ¿qué indica el LED P32?")
    assert_not Rag::BoardHeading.mentioned?("ARCA II", "")
  end

  # Truth table measured against the real headings and questions from the 5
  # pilot gate runs (see the plan's Fase 1.1/1.3). Each row is a defect this
  # rewrite fixes: D1 (unicode dash breaks the tokenizer), D2 (a brand/prose
  # suffix must not force an exact-token match), D3 (generic table headings
  # are not a board), D4 (the same board fragmenting across heading spellings).
  QUESTIONS = {
    tpr60_pp: "En el modelo TPR60 de Carlos Silva, ¿a qué serie corresponde el LED PP?",
    tpr70_epc_b8: "En TPR70, ¿a qué conector está conectado EPC?",
    cta_cr8ph2_sph: "En la placa CR8PH2 de CTA, ¿qué LED indica que las puertas cabina/exterior " \
                    "están cerradas y en qué placa se encuentra?",
    cta_sr8p_sph: "En la placa SR8P de CTA, ¿qué LED indica que las puertas cabina/exterior " \
                  "están cerradas y en qué placa se encuentra?",
    em2000_contradiccion: "En EM2000, ¿qué conectores de fotocélula aparecen en el encabezado y en el dibujo?",
    em4000_obstaculo_conectores: "En EM4000 V1, ¿qué conectores documenta el encabezado del obstáculo en la placa?",
    em1000_v1_tabla: "En la placa EM 1000 V1, lista los LEDs y la serie que indica cada uno.",
    tpr50_spm: "En el modelo TPR50 de Carlos Silva, ¿a qué serie corresponde el LED SPM?",
    twister_embarba_puertas: "Estoy con una Twister TW de Embarba eléctrica y sospecho de la serie de " \
                              "puertas. ¿Qué LED de la placa me lo confirma?",
    spm_sin_placa: "¿A qué serie corresponde el LED SPM?",
    dl2_sin_placa: "¿Qué serie indica el LED DL2?",
    arca2_p32: "En la placa ARCA II, ¿qué serie indica el LED P32?",
    arca_vs_arca3_p32: "En la placa ARCA básica, ¿qué serie indica el LED P32? " \
                        "¿Significa lo mismo en ARCA III?",
    miconic_lx_tabla: "En la placa MICONIC LX de Schindler, lista los LEDs T1 a T5 y la serie que " \
                       "indica cada uno.",
    ksa18_h14: "En la placa KSA 18 hidráulica de Recoba, ¿qué indica el LED H14 y cuál es su estado normal?",
    cmc4_tabla: "En la placa CMC 4 de Thyssen, lista los LEDs y qué indica cada uno."
  }.freeze

  test "mentioned? truth table from the 5 pilot gate runs" do
    [
      [ "HIDRA–TPR60 Board Connectors and Safety Series Overview", :tpr60_pp, true ],
      [ "HIDRA–TPR70 Conexionado de Seguridades y Entradas", :tpr60_pp, false ],
      [ "HIDRA–TPR70 Conexionado de Seguridades y Entradas", :tpr70_epc_b8, true ],
      [ "HIDRA–TPR60 Board Connectors and Safety Series Overview", :tpr70_epc_b8, false ],
      [ "CTA – ELECTRICO Y HIDRAULICO PREMONTADA", :cta_cr8ph2_sph, true ],
      [ "CTA – SR8P (ELÉCTRICO Y HIDRÁULICO) — BORNAS CARRIL", :cta_sr8p_sph, true ],
      [ "EM 2000 - ELÉCTRICO", :em2000_contradiccion, true ],
      [ "Placa EM 4000 V1", :em4000_obstaculo_conectores, true ],
      [ "Placa EM 4000 V1", :em1000_v1_tabla, false ],
      [ "HIDRA – TPR50 Safety Chain & Terminal Wiring Overview", :tpr50_spm, true ],
      [ "TWISTER TW - INAPELSA", :tpr50_spm, false ],
      [ "TWISTER TW - INAPELSA", :twister_embarba_puertas, true ],
      [ "TWISTER TW - INAPELSA", :spm_sin_placa, false ],
      [ "DELTA + — LED Series", :spm_sin_placa, false ],
      [ "LEVEL CONTROL 1B – ELECTRICO - PREMONTADA", :dl2_sin_placa, false ],
      [ "ARCA II Safety Chain & Connector Layout", :arca2_p32, true ],
      [ "ARCA II Safety Chain & Connector Layout", :arca_vs_arca3_p32, false ],
      [ "Diagrama de Cadena de Seguridades — Placa ARCA", :arca_vs_arca3_p32, true ],
      [ "Diagrama de cadena de seguridades ARCA III (Orona PDCM 5124537)", :arca_vs_arca3_p32, true ],
      [ "MICONIC BX-6200", :miconic_lx_tabla, false ],
      [ "Tabla de LEDs de la cadena serie — MICONIC LX", :miconic_lx_tabla, true ],
      [ "S6 — ELECTRICAL: RECOBA – LIFT CNTROL - EKM64", :ksa18_h14, false ],
      [ "S7 — DIAGRAM: CMC 4 — Placa UBA-CMC4", :cmc4_tabla, true ]
    ].each do |heading, question_key, expected|
      question = QUESTIONS.fetch(question_key)
      actual = Rag::BoardHeading.mentioned?(heading, question)
      assert_equal expected, actual,
                   "expected mentioned?(#{heading.inspect}, #{question_key.inspect}) to be #{expected}"
    end
  end

  test "board_tokens is empty for a generic table/diagram heading with no board name" do
    [
      "S7",
      "Tabla de placas y series",
      "LED Series Indicators (tabla visible en el diagrama)",
      "Tabla de LEDs de serie (visible en página)",
      "LED STATUS — Tabla de series de LEDs",
      "Placa principal — Identificación de conectores visibles",
      "LEDs de Estado — Tabla de Series"
    ].each do |heading|
      assert_empty Rag::BoardHeading.board_tokens(heading),
                   "expected #{heading.inspect} to be recognized as a generic heading"
    end
  end

  test "board_tokens is not empty for a heading that names a real board" do
    [
      "TWISTER TW - INAPELSA",
      "EM 2000 - ELÉCTRICO",
      "Placa EM 4000 V1",
      "MICONIC BX-6200",
      "Diagrama de Cadena de Seguridades — Placa ARCA",
      "ARCA II Safety Chain & Connector Layout"
    ].each do |heading|
      assert_not_empty Rag::BoardHeading.board_tokens(heading),
                        "expected #{heading.inspect} to still be recognized as a board"
    end
  end
end
