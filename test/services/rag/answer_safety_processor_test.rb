# frozen_string_literal: true

require "test_helper"

class Rag::AnswerSafetyProcessorTest < ActiveSupport::TestCase
  # Expected user-facing strings are pulled from I18n so this source file stays
  # ASCII while still asserting the exact localized copy.
  def t(key, **opts)
    I18n.t("rag.#{key}", locale: :es, **opts)
  end

  test "renders both internal field-verification spellings and data absence" do
    answer = <<~TEXT
      Torque: DATA_NOT_AVAILABLE.
      Conexion: REQUIRE_FIELD_VERIFICATION.
      Diagrama: REQUIRES_FIELD_VERIFICATION.
    TEXT

    rendered = processor.call(answer, evidence: [])

    assert_no_match(/DATA_NOT_AVAILABLE|REQUIRES?_FIELD_VERIFICATION/, rendered)
    assert_includes rendered, t("data_not_available")
    assert_equal 2, rendered.scan(t("requires_field_verification")).size
  end

  test "ignores legacy citation values that do not carry chunk content" do
    assert_equal "Test answer", processor.call("Test answer", evidence: [ "manual.pdf" ])
  end

  test "removes a statement containing identifiers absent from evidence" do
    answer = "La fotocelula se conecta a XSSC y XSSH2.\nConservar esta advertencia."
    evidence = [ { content: "La conexion documentada corresponde a B8." } ]

    rendered = processor.call(answer, evidence: evidence)

    assert_not_includes rendered, "XSSC"
    assert_not_includes rendered, "XSSH2"
    assert_includes rendered, t("unsupported_identifier")
    assert_includes rendered, "Conservar esta advertencia"
  end

  test "preserves supported connector terminal and LED identifiers" do
    answer = "XP31 enlaza CN-112.SC con CN-109.CC y C2. Los LED D8, DL27, L9 y T4 estan identificados."
    evidence = [ { content: "XP31 CN-112.SC CN-109.CC C2 D8 DL27 L9 T4" } ]

    assert_equal answer, processor.call(answer, evidence: evidence)
  end

  test "detects when an answer requires evidence fallback" do
    assert Rag::AnswerSafetyProcessor.requires_evidence?("El LED D8 encendido.")
    assert Rag::AnswerSafetyProcessor.requires_evidence?("La alimentacion es 220 V.")
    assert_not Rag::AnswerSafetyProcessor.requires_evidence?("No hay informacion suficiente.")
  end

  test "fails closed when a technical generative answer has no cited evidence" do
    rendered = processor.call(
      "La alimentacion documentada es 220 V.",
      evidence: [],
      require_cited_evidence: true
    )

    assert_equal t("uncited_technical_answer"), rendered
    assert_not_includes rendered, "220 V"
  end

  test "preserves a substantive summary answer without technical tokens even without a citation" do
    # F3 acotado: fail-closed only fires on evidence-sensitive claims. A plain
    # summary/abstention is delivered as-is instead of being destroyed.
    answer = "El manual describe el sistema de seguridad."

    assert_equal answer, processor.call(answer, evidence: [], require_cited_evidence: true)
  end

  test "allows an explicit absence marker without a citation" do
    rendered = processor.call("DATA_NOT_AVAILABLE", evidence: [], require_cited_evidence: true)

    assert_equal t("data_not_available"), rendered
  end

  test "allows a technical generative answer when cited evidence is present" do
    answer = "La alimentacion documentada es 220 V."
    evidence = [ { content: "FOTOCELULA 220 V" } ]

    assert_equal answer, processor.call(answer, evidence: evidence, require_cited_evidence: true)
  end

  test "degrades the whole claim when known and unknown identifiers are mixed" do
    answer = "La conexion es B8, no B7."
    evidence = [ { content: "EPC se conecta en B8." } ]

    rendered = processor.call(answer, evidence: evidence)

    assert_not_includes rendered, "B7"
    assert_not_includes rendered, "B8"
    assert_includes rendered, t("unsupported_identifier")
  end

  test "rejects a component connector pair that does not share an evidence fragment" do
    answer = "EPC se conecta a B7."
    evidence = [ { content: "EPC se conecta a B8.\nPRESOSTATO se conecta a B7." } ]

    rendered = processor.call(answer, evidence: evidence)

    assert_not_includes rendered, "EPC se conecta a B7"
    assert_includes rendered, t("unsupported_connection")
  end

  test "preserves an explicitly documented component connector pair" do
    answer = "EPC se conecta a B8."
    evidence = [ { content: "EPC se conecta a B8." } ]

    assert_equal answer, processor.call(answer, evidence: evidence)
  end

  test "the joined absence sentinels are not treated as connector components" do
    answer = "El conector documentado es XQ22 — DATA_NOT_AVAILABLE REQUIRES_FIELD_VERIFICATION."
    evidence = [ { content: "El conector documentado es XQ22." } ]

    rendered = processor.call(answer, evidence: evidence)

    assert_includes rendered, "XQ22"
    assert_includes rendered, t("data_not_available")
    assert_includes rendered, t("requires_field_verification")
    assert_not_includes rendered, t("unsupported_connection")
  end

  test "does not treat search aliases as component connector evidence" do
    rendered = processor.call(
      "CERROJOS CABINA se conectan a B8.",
      evidence: [
        {
          content: <<~TEXT
            [SEARCH_ALIASES: B8, CERROJOS CABINA]
            | EPC | SERIE CERROJOS CABINA |
            | B8 | ACUNAMIENTO, AFLOJA CABLES |
          TEXT
        }
      ]
    )

    assert_not_includes rendered, "CERROJOS CABINA se conectan a B8"
    assert_includes rendered, t("unsupported_connection")
  end

  test "preserves citation markers when degrading an unsupported claim" do
    rendered = processor.call(
      "DL27 se enciende durante un fallo[1].",
      evidence: [ { content: "El esquema identifica DL27." } ]
    )

    assert_includes rendered, "#{t('undocumented_led_logic', identifier: 'DL27')}[1]"
  end

  test "degrades invented LED state while preserving a documented state" do
    unsupported = processor.call(
      "DL27 se enciende durante un fallo.",
      evidence: [ { content: "El esquema identifica DL27." } ]
    )
    supported = processor.call(
      "DL27 se enciende durante un fallo.",
      evidence: [ { content: "DL27 se enciende durante un fallo." } ]
    )

    assert_equal "#{t('undocumented_led_logic', identifier: 'DL27')}\n", unsupported
    assert_equal "DL27 se enciende durante un fallo.", supported
  end

  test "degrades an unsupported limiter overload characterization" do
    rendered = processor.call(
      "El limitador D8 protege contra sobrecarga.",
      evidence: [ { content: "Dispositivo de seguridad: limitador D8." } ]
    )

    assert_not_includes rendered, "sobrecarga"
    assert_includes rendered, t("unsupported_device_function")
  end

  # F3 regression: MR08 fotocelulas SCI -- CN-112.SC / CN-109.CC are documented on
  # page 22. Validation against the retrieved chunks (not only native citations)
  # must keep the correct identifiers instead of falsely rejecting them.
  test "preserves documented MR08 connectors validated against retrieved chunks" do
    answer = "En MR08, las fotocelulas SCI se conectan en CN-112.SC y CN-109.CC."
    evidence = [ { content: "Las fotocelulas SCI se conectan en CN-112.SC y CN-109.CC." } ]

    assert_equal answer, processor.call(answer, evidence: evidence, require_cited_evidence: true)
  end

  # F3 regression: TOKIBAT -- degrading the DL27 logic line must not leave the
  # "Cuando se enciende:" heading orphaned with no body beneath it.
  test "removes an orphaned heading left without a body" do
    answer = "DL27 esta identificado en el esquema.\n\n**Cuando se enciende:**\n"
    evidence = [ { content: "El esquema identifica DL27." } ]

    rendered = processor.call(answer, evidence: evidence)

    assert_includes rendered, "DL27 esta identificado en el esquema."
    assert_not_includes rendered, "Cuando se enciende"
  end

  test "keeps a heading that still has a documented body beneath it" do
    answer = "Estado documentado:\nDL27 se enciende durante un fallo."
    evidence = [ { content: "DL27 se enciende durante un fallo." } ]

    rendered = processor.call(answer, evidence: evidence)

    assert_includes rendered, "Estado documentado:"
    assert_includes rendered, "DL27 se enciende durante un fallo."
  end

  test "a trailing orphan header is still pruned when an absence paragraph follows" do
    answer = "La etiqueta ZR7-K1 está documentada.\n\n**Condición restante:**\n\nDATA_NOT_AVAILABLE"
    evidence = [ { content: "La etiqueta ZR7-K1 está documentada." } ]

    rendered = processor.call(answer, evidence: evidence)

    assert_includes rendered, "ZR7-K1"
    assert_not_includes rendered, "Condición restante"
    assert_includes rendered, t("data_not_available")
  end

  # altius_d9_d10: "indica"/"señala" alone name a documented series/label
  # attribution, not ON/OFF logic, so the guard must not fire on them even
  # without a state term in the evidence.
  test "preserves a series/label attribution using indica without a state term" do
    answer = "D10 indica la SERIE SEGURIDAD CABINA."
    evidence = [ { content: "D9 | SERIE SEGURIDADES HUECO\nD10 | SERIE SEGURIDAD CABINA" } ]

    assert_equal answer, processor.call(answer, evidence: evidence)
  end

  test "still degrades an indica claim when it is paired with a state term and unsupported" do
    rendered = processor.call(
      "DL27 indica que se enciende en fallo.",
      evidence: [ { content: "El esquema identifica DL27." } ]
    )

    assert_includes rendered, t("undocumented_led_logic", identifier: "DL27")
  end

  # thyssen_e_led negative control: an assertive normal/fault attribution
  # without documented evidence must still be blocked.
  test "still degrades an unsupported assertive normal/fault attribution using señala" do
    rendered = processor.call(
      "L9 señala fallo cuando ocurre una avería.",
      evidence: [ { content: "El esquema identifica L9." } ]
    )

    assert_includes rendered, t("undocumented_led_logic", identifier: "L9")
  end

  # tokibat_dl27 negative control: a bare state-verb assertion is unaffected
  # by the indica/señala carve-out and stays blocked.
  test "still degrades a bare state-verb assertion with no evidence" do
    rendered = processor.call(
      "DL27 se enciende cuando ocurre un fallo.",
      evidence: [ { content: "El esquema identifica DL27." } ]
    )

    assert_includes rendered, t("undocumented_led_logic", identifier: "DL27")
  end

  # edel_k2_c2 (12-case rubric): the connection-claim guard treated the board's
  # own model name and a "(SERIE ...)" category label as unsupported wired
  # "components" of the connector they were merely mentioned alongside,
  # intermittently destroying a correct answer depending on phrasing.
  test "preserves a connector line that only mentions the board's own model name" do
    answer = "En el diagrama EDEL-K2, el bloque de terminales C2 muestra las siguientes posiciones de terminal: 37, 38, 41."
    evidence = [ { content: "C2 (red border) — terminal positions labeled: 37, 38, 41." } ]

    assert_equal answer, processor.call(answer, evidence: evidence)
  end

  test "preserves a connector line naming a documented SERIE category label" do
    answer = "41 (SERIE CERROJOS CABINA) si aparece como terminal en el bloque C2."
    evidence = [ { content: "C2 (red border) — terminal positions labeled: 37, 38, 41.\n| 41 | SERIE CERROJOS CABINA |" } ]

    assert_equal answer, processor.call(answer, evidence: evidence)
  end

  # Mandatory negative control: the SERIE-label and digit-code carve-outs must
  # not open a hole for a genuinely invented connector/component pairing.
  test "still rejects an invented connector pairing despite the SERIE/digit carve-outs" do
    answer = "EPC se conecta a B7 (SERIE PRUEBAS)."
    evidence = [ { content: "EPC se conecta a B8.\nPRESOSTATO se conecta a B7." } ]

    rendered = processor.call(answer, evidence: evidence)

    assert_not_includes rendered, "EPC se conecta a B7"
    assert_includes rendered, t("unsupported_connection")
  end

  # mr08_sci (12-case rubric): the blanket digit exclusion added for the
  # EDEL-K2 board-name carve-out also threw out pin labels enumerated
  # alongside a connector (PC3..PC7), leaving no evidenced "component" for
  # the C1/C2 pins in the same sentence and destroying a fully-evidenced
  # connector/series line. The carve-out is now scoped to hyphenated model
  # designations (EDEL-K2), not any digit-bearing code.
  test "preserves a connector line whose pin enumeration includes digit-bearing pin labels" do
    answer = "Según el diagrama de conexionado, la serie SCI (SERIE OBSTACULO) está asociada a estos " \
      "conectores: CN-112.SC y CN-109.CC. El conector CN-112 presenta los pines SC, PCP y NIV, " \
      "mientras que CN-109 dispone de los pines C1, C2, PC3, PC4, PC5, PC6 y PC7."
    evidence = [ { content: <<~TEXT } ]
      | SCI | SERIE OBSTACULO (CN-112.SC y CN-109.CC) |
      CN-112 — conector placa MR08; pines visibles: SC, PCP, NIV
      CN-109 — conector placa MR08; pines visibles: C1, C2, PC3, PC4, PC5, PC6, PC7
    TEXT

    assert_equal answer, processor.call(answer, evidence: evidence)
  end

  private

  def processor
    @processor ||= Rag::AnswerSafetyProcessor.new(locale: :es)
  end
end
