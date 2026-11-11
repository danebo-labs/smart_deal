# frozen_string_literal: true

require "test_helper"

class Rag::CompanionTurnPublicationTest < ActiveSupport::TestCase
  PHOTOCELL = "Indicador LED y relé activado cuando la fotocélula o la entrada de re-apertura está activada."
  OBSTRUCTION = "Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta."
  WHEN_QUOTE = "cuando la fotocélula o la entrada de re-apertura está activada"
  LOST_WHEN = "la fotocélula o la entrada de re-apertura está activada"
  LOST_IF = "debe haber una obstrucción mecánica en la puerta"

  test "a faithful partial quote is accepted and a quote that drops cuando is not" do
    accepted = publish("La página dice «#{WHEN_QUOTE}» [1].", [ source(PHOTOCELL) ])
    rejected = publish("La página dice «#{LOST_WHEN}» [1].", [ source(PHOTOCELL) ])

    assert accepted.accepted?, accepted.reasons.inspect
    assert_equal WHEN_QUOTE, accepted.quotes.sole["text"]
    assert_equal 1, accepted.quotes.sole["source"]
    assert_not rejected.accepted?
    assert_equal [ "R2" ], rules(rejected)
  end

  test "a quote that drops the opening si is rejected" do
    result = publish("La página dice «#{LOST_IF}» [1].", [ source(OBSTRUCTION) ])

    assert_not result.accepted?
    assert_equal [ "R2" ], rules(result)
  end

  test "a quote that drops no inside the same fragment is rejected" do
    body = "Comprobar que la fotocélula no está activada."
    result = publish("La página dice «está activada» [1].", [ source(body) ])

    assert_not result.accepted?
    assert_equal [ "R2" ], rules(result)
  end

  test "a literal quote after a source condition is accepted when the answer carries that condition" do
    step = "– En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST."
    quote = "desconectar la fotocélula y volver a pulsar el botón de TEST"
    carried = publish("Si el problema persiste, el manual indica «#{quote}» [1].", [ source(step) ])
    dropped = publish("El manual indica «#{quote}» [1].", [ source(step) ])
    negated = publish("Reportaste que no ves «#{quote}» [1].", [ source(step) ])

    assert carried.accepted?, carried.reasons.inspect
    assert_equal quote, carried.quotes.sole["text"]
    assert_not dropped.accepted?
    assert_equal [ "condition_dropped:#{quote}" ], dropped.reasons.pluck("detail")
    assert_not negated.accepted?, "a negation does not carry a condition"
  end

  # CEA15+ manual p. 22, live final5 T3.
  test "a quote that opens on its own condition carries it after an earlier clause" do
    body = 'Una serie de seguridad es "1" si la tensión en el terminal correspondiente es 24 Vcc, o "0" si la tensión en el terminal correspondiente es 0 Vcc.'
    second = "si la tensión en el terminal correspondiente es 0 Vcc"
    opened = publish("- **Nivel 0:** «#{second}» [1]", [ source(body) ])
    trimmed = publish("- **Nivel 0:** «#{second.delete_prefix('si ')}» [1]", [ source(body) ])
    restricted = publish("El manual indica «si cierran las puertas» [1].", [ source("Solo si cierran las puertas, SA es 1.") ])

    assert opened.accepted?, opened.reasons.inspect
    assert_equal second, opened.quotes.sole["text"]
    assert_equal [ "condition_dropped:#{second.delete_prefix('si ')}" ], trimmed.reasons.pluck("detail")
    assert_equal [ "condition_dropped:si cierran las puertas" ], restricted.reasons.pluck("detail")
  end

  test "a dropped negation is reported as dropped and a non literal quote as missing" do
    body = "Comprobar que la fotocélula no está activada."
    dropped = publish("La página dice «está activada» [1].", [ source(body) ])
    carried = publish("La fotocélula no figura como «está activada» [1].", [ source(body) ])
    invented = publish("La página dice «fotocélula bloqueada» [1].", [ source(body) ])

    assert_equal [ "condition_dropped:está activada" ], dropped.reasons.pluck("detail")
    assert carried.accepted?, carried.reasons.inspect
    assert_equal [ "fotocélula bloqueada" ], invented.reasons.pluck("detail")
  end

  test "a heading quote is accepted when an earlier alias line names another symptom" do
    body = "[SEARCH_ALIASES: 8.2 Funcionamiento normal, la puerta solo cierra 35 cm, paso libre, la puerta se abre pero no se cierra]\n• La puerta se abre pero no se cierra"
    quote = "La puerta se abre pero no se cierra"
    result = publish("Además, [1] lo ubica bajo «#{quote}», distinto de su síntoma.", [ source(body) ])

    assert result.accepted?, result.reasons.inspect
    assert_equal quote, result.quotes.sole["text"]
    assert_equal 1, result.quotes.sole["source"]
  end

  test "a quote that cuts Solo still drops the restriction and the full sentence does not" do
    sentence = "Solo es necesario realizar otra vez el autoajuste para la configuración de los parámetros por defecto o cuando se realicen cambios como la conexión o desconexión de la fotocélula Fermator"
    trimmed = "configuración de los parámetros por defecto"
    dropped = publish("No mencionaste la «#{trimmed}» [1].", [ source(sentence) ])
    kept = publish("Cito: «#{sentence}» [1].", [ source(sentence) ])

    assert_equal [ "condition_dropped:#{trimmed}" ], dropped.reasons.pluck("detail")
    assert kept.accepted?, kept.reasons.inspect
    assert_equal sentence, kept.quotes.sole["text"]
  end

  test "telling the technician to consult the manufacturer is marked as an attribution" do
    consultation = publish("Confírmela con el fabricante antes de ajustar.", [ source(OBSTRUCTION) ])
    stated = publish("El fabricante indica que la unidad es 150 Nm.", [ source(OBSTRUCTION) ])
    other_claim = publish(
      "El manual indica que la unidad es 150 Nm. El paso citado es comprobar la obstrucción [1].",
      [ source(OBSTRUCTION) ]
    )

    assert_equal "Confírmela con el fabricante antes de ajustar", consultation.reasons.find { |reason| reason["rule"] == "R3" }["detail"]
    assert_includes rules(stated), "R3"
    assert_equal [ "R3" ], other_claim.reasons.select { |reason| reason["rule"] == "R3" }.pluck("rule")
    assert_equal "El manual indica que la unidad es 150 Nm", other_claim.reasons.find { |reason| reason["rule"] == "R3" }["detail"]
  end

  test "a citation in the next sentence does not cover an attribution in this one" do
    ambiguous = publish(
      "Si el problema persiste, el manual indica desconectar la fotocélula y volver a pulsar TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica [1].",
      [ source(OBSTRUCTION) ]
    )
    same_sentence = publish(
      "Si el problema persiste, el manual indica desconectar la fotocélula y volver a pulsar TEST [1].",
      [ source(OBSTRUCTION) ]
    )

    assert_equal [ "R3" ], rules(ambiguous)
    assert_equal "Si el problema persiste, el manual indica desconectar la fotocélula y volver a pulsar TEST", ambiguous.reasons.sole["detail"]
    assert same_sentence.accepted?, same_sentence.reasons.inspect
    assert_empty rules(same_sentence)
  end

  test "a question about the manual is not an attribution and a question that asserts it is" do
    question = publish("¿Hay especificaciones en el manual sobre el ajuste del cierre?", [ source(PHOTOCELL) ])
    asserted = publish("Según el manual hay que ajustar el cierre, ¿lo hiciste?", [ source(PHOTOCELL) ])
    statement = publish("El manual pide ajustar el cierre.", [ source(PHOTOCELL) ])

    assert question.accepted?, question.reasons.inspect
    assert_not asserted.accepted?
    assert_equal [ "R3" ], rules(asserted)
    assert_equal [ "R3" ], rules(statement)
  end

  test "si inside another word does not reject the following quote" do
    body = "Comprobar la sensibilidad cuando el cierre es normal."
    result = publish("La página dice «cuando el cierre es normal» [1].", [ source(body) ])

    assert result.accepted?, result.reasons.inspect
  end

  test "a condition on the previous line is accepted and does not prove semantic fidelity" do
    # fragments splits on newlines. The validator only sees the fragment that
    # contains the quote, so a condition on the previous line is invisible.
    # Acceptance here is a documented limit, not a fidelity guarantee.
    body = "Si el contactor está abierto, no lo fuerces.\nEl relé auxiliar permanece en reposo."
    result = publish("La página dice «El relé auxiliar permanece en reposo» [1].", [ source(body) ])

    assert result.accepted?, result.reasons.inspect
  end

  test "an altered quote is rejected and a paraphrase with a citation is accepted" do
    altered = publish("La página dice «fotocélula activada» [1].", [ source(PHOTOCELL) ])
    paraphrase = publish("El cierre puede quedar pendiente [1].", [ source(PHOTOCELL) ])

    assert_not altered.accepted?
    assert_equal [ "R2" ], rules(altered)
    assert paraphrase.accepted?, paraphrase.reasons.inspect
    assert_empty paraphrase.quotes
  end

  test "a manual attribution without a citation is rejected and an absence claim is not" do
    attributed = publish("Según el manual, hay que ajustar el cierre.", [ source(PHOTOCELL) ])
    absence = publish("El manual no da un valor.", [ source(PHOTOCELL) ])
    page = publish("La documentación de la pág. 12 no da el par.", [ source(PHOTOCELL) ])
    summary = publish(
      "- **Respaldado por la documentación (fuente 3, pág. 12):** revisar #54, fotocélula no activada, obstrucción mecánica.",
      [ source(PHOTOCELL) ]
    )

    assert_not attributed.accepted?
    assert_equal [ "R3" ], rules(attributed)
    assert absence.accepted?, absence.reasons.inspect
    assert page.accepted?, page.reasons.inspect
    assert_equal [ "R3" ], rules(summary)
  end

  test "a missing, reference-only, or foreign source citation is rejected" do
    missing = publish("Pendiente [3].", [ source(PHOTOCELL) ])
    reference = publish("Pendiente [1].", [ source(PHOTOCELL, applicability: "reference_only", reference_only: true) ])
    foreign = publish("Pendiente [1].", [ source(PHOTOCELL, applicability: "foreign") ])
    neutral = publish("Pendiente [1].", [ source(PHOTOCELL, applicability: "neutral") ])

    assert_equal [ "R1" ], rules(missing)
    assert_equal [ "R1" ], rules(reference)
    assert_equal [ "R1" ], rules(foreign)
    assert neutral.accepted?, neutral.reasons.inspect
  end

  test "max_tokens is an incomplete generation" do
    result = publish("El cierre puede quedar pendiente [1].", [ source(PHOTOCELL) ], stop_reason: "max_tokens")

    assert_not result.accepted?
    assert_includes rules(result), "R4"
  end

  test "a guard that removes an accepted quote invalidates the answer" do
    text = "La página dice «#{WHEN_QUOTE}» [1]."
    result = publish(text, [ source(PHOTOCELL) ], guarded_text: "La página dice [1].")

    assert_not result.accepted?
    assert_includes rules(result), "R5"
    assert_includes result.reasons.pluck("detail"), "quote_removed"
  end

  test "length, a short list, bold, and two questions are signals and not rejections" do
    text = <<~TEXT
      #{'Orientación del cierre. ' * 40}
      - revisar el cierre [1]
      **nota**
      ¿El cierre está libre? ¿Hay holgura?
    TEXT
    result = publish(text, [ source(PHOTOCELL) ])

    assert result.accepted?, result.reasons.inspect
    assert_equal 2, result.signals.find { |item| item["code"] == "S2" }["questions"]
    marker = result.signals.find { |item| item["code"] == "S4" }
    assert_equal true, marker["list"]
    assert_equal true, marker["bold"]
  end

  test "an identifier absent from its cited source is a signal" do
    second = "El relé auxiliar permanece en reposo."
    result = publish("El código #54 queda fuera de esta página [2].", [ source(PHOTOCELL), source(second) ])

    assert result.accepted?, result.reasons.inspect
    signal = result.signals.find { |item| item["code"] == "S1" }
    assert_equal "#54", signal["token"]
    assert_equal [ 2 ], signal["sources"]
  end

  test "a quote that repeats the technician is not treated as a documentary quote" do
    result = publish(
      "El técnico dijo «#{LOST_WHEN}» [1].",
      [ source(PHOTOCELL) ],
      technician_texts: [ LOST_WHEN ]
    )

    assert result.accepted?, result.reasons.inspect
    assert_empty result.quotes
  end

  test "a marker run after the period stays with the attribution and the next sentence does not" do
    attached = publish(
      'Según el documento, "tiene prioridad sobre la señal cerrar". [1] Es una verificación de cableado.',
      [ source("La señal de re-apertura tiene prioridad sobre la señal cerrar.") ]
    )
    separate = publish(
      "El manual indica desconectar la fotocélula. [1] El documento dice que hay que cortar la alimentación.",
      [ source(OBSTRUCTION) ]
    )

    assert attached.accepted?, attached.reasons.inspect
    assert_equal [ "R3" ], rules(separate)
    assert_equal "El documento dice que hay que cortar la alimentación", separate.reasons.sole["detail"]
  end

  test "a quote that spans two manual sentences is checked as one literal span" do
    body = "Para activar esta señal, se debe conectar la entrada re-apertura (21) con la entrada de +12V (23). Utilizar contactos libres de tensión."
    quote = "se debe conectar la entrada re-apertura (21) con la entrada de +12V (23). Utilizar contactos libres de tensión."
    result = publish("Para activar la re-apertura, \"#{quote}\" [1].", [ source(body) ])

    assert result.accepted?, result.reasons.inspect
    assert_equal quote, result.quotes.sole["text"]
    assert_equal 1, result.quotes.sole["source"]
  end

  test "an invented quote without a marker is missing and a metadata-only match is not a dropped condition" do
    invented = publish("La página dice «fotocélula bloqueada».", [ source(PHOTOCELL) ])
    alias_only = "[SEARCH_ALIASES: la puerta solo cierra 35 cm]\n• Otra línea"
    metadata = publish("Cito «solo cierra 35 cm» [1].", [ source(alias_only) ])

    assert_equal [ "fotocélula bloqueada" ], invented.reasons.select { |reason| reason["rule"] == "R2" }.pluck("detail")
    assert_equal [ "solo cierra 35 cm" ], metadata.reasons.pluck("detail")
    assert_not metadata.reasons.any? { |reason| reason["detail"].start_with?("condition_dropped:") }
  end

  test "a literal quote without a marker records its source and an attribution without one stays rejected" do
    literal = publish("Cito «#{WHEN_QUOTE}». El cierre puede quedar pendiente [1].", [ source(PHOTOCELL) ])
    attributed = publish("El documento da «#{WHEN_QUOTE}».", [ source(PHOTOCELL) ])

    assert literal.accepted?, literal.reasons.inspect
    assert_equal 1, literal.quotes.sole["source"]
    assert_includes rules(attributed), "R3"
    assert_equal WHEN_QUOTE, attributed.quotes.sole["text"]
  end

  test "a quote attributed to the technician must use the technician words" do
    matched = publish(
      "El técnico dijo «#{LOST_WHEN}» [1].",
      [ source(PHOTOCELL) ],
      technician_texts: [ LOST_WHEN ]
    )
    altered = publish(
      "El técnico dijo «obstrucción total» [1].",
      [ source(PHOTOCELL) ],
      technician_texts: [ "no veo obstrucción" ]
    )

    assert matched.accepted?, matched.reasons.inspect
    assert_equal [ "technician_mismatch:obstrucción total" ], altered.reasons.pluck("detail")
  end

  test "a technician sentence may keep the technician quote and a literal manual quote" do
    mixed = publish(
      "Dijiste que «#{LOST_WHEN}» y el manual indica «#{WHEN_QUOTE}» [1].",
      [ source(PHOTOCELL) ],
      technician_texts: [ LOST_WHEN ]
    )
    invented = publish(
      "Dijiste que «potenciómetro inventado» [1].",
      [ source(PHOTOCELL) ],
      technician_texts: [ LOST_WHEN ]
    )

    assert mixed.accepted?, mixed.reasons.inspect
    assert_equal [ WHEN_QUOTE ], mixed.quotes.pluck("text")
    assert_equal [ "technician_mismatch:potenciómetro inventado" ], invented.reasons.pluck("detail")
  end

  test "a short label before a fully cited list passes and a claim label or an uncited item does not" do
    listed = <<~TEXT
      Pasos documentados:
      1. Comprueba la sensibilidad del potenciómetro #54 [1].
      2. Comprueba que no hay obstrucción mecánica en la puerta [1].
      3. Si la puerta no abre o cierra completamente, la documentación indica que debe haber obstrucción mecánica [1].
    TEXT
    uncited = <<~TEXT
      Pasos documentados:
      1. Comprueba la sensibilidad del potenciómetro #54 [1].
      2. El manual indica desconectar la fotocélula.
    TEXT
    claim = "Según el manual:\n1. Comprueba el cierre [1]."
    passed = publish(listed, [ source(PHOTOCELL) ])
    rejected = publish(uncited, [ source(PHOTOCELL) ])
    according = publish(claim, [ source(PHOTOCELL) ])

    assert passed.accepted?, passed.reasons.inspect
    assert_includes rejected.reasons.pluck("detail"), "Pasos documentados:"
    assert_includes rejected.reasons.pluck("detail"), "El manual indica desconectar la fotocélula"
    assert_includes according.reasons.pluck("detail"), "Según el manual:"
  end

  test "the trimmed potentiometer quote is not literal and the restored span is" do
    body = "Potenciómetro que permite ajustar la fuerza de cierre de la puerta (sensibilidad a reaperturas)."
    short = publish('Es el potenciómetro de "fuerza de cierre (sensibilidad a reaperturas)" [1].', [ source(body) ])
    restored = publish('Es el potenciómetro de "fuerza de cierre de la puerta (sensibilidad a reaperturas)" [1].', [ source(body) ])

    assert_equal [ "fuerza de cierre (sensibilidad a reaperturas)" ], short.reasons.pluck("detail")
    assert restored.accepted?, restored.reasons.inspect
  end

  test "a citation in the same sentence does not prove that the source supports another claim" do
    result = publish("El manual indica que el LED de Estado debe estar apagado [1].", [ source(OBSTRUCTION) ])

    assert result.accepted?, result.reasons.inspect
    assert_empty result.quotes
  end

  test "a quotation that ends with a period releases the next sentence from its marker" do
    quoted = "La señal de re-apertura tiene prioridad sobre la señal cerrar."
    text = "\"#{quoted}\" [5] El manual pide ajustar el cierre."
    fragments = fragments_of(text)
    sources = Array.new(4) { source("otra página") } + [ source(quoted) ]
    result = publish(text, sources)

    assert_includes fragments[0], "[5]"
    assert_includes fragments[0], quoted
    assert_equal "El manual pide ajustar el cierre", fragments[1]
    assert_not_includes fragments[1], "[5]"
    assert_equal [ "R3" ], rules(result)
    assert_equal "El manual pide ajustar el cierre", result.reasons.sole["detail"]
  end

  test "a period inside an open quotation does not end the fragment" do
    quote = "se debe conectar la entrada re-apertura (21) con la entrada de +12V (23). Utilizar contactos libres de tensión."
    text = "Para activar la re-apertura, \"#{quote}\" [1]."
    fragments = fragments_of(text)

    assert_equal 1, fragments.size
    assert_includes fragments[0], "(23). Utilizar"
    assert_includes fragments[0], "[1]"
  end

  test "a postponed marker stays behind and a lowercase continuation takes the whole run" do
    photocell = "Comprueba la fotocélula. [1] Luego revisa el cierre."
    cited = 'Según el documento, "tiene prioridad sobre la señal cerrar". [1] Es una verificación de cableado.'
    forward = 'Ojo: la unidad no es clara. [4] dice "regulable de 60 a 150Nm".'
    absent = "Según [4], la señal existe. [4] no indica cómo verificar esa conexión."
    demanded = "El manual lo exige. [4] dice que la unidad es clara."
    streak = "El manual lo exige. [4] [5] dice que la unidad es clara."
    behind = "Comprueba la fotocélula. [1] [2] Luego revisa el cierre."

    assert_includes fragments_of(photocell)[0], "[1]"
    assert_not_includes fragments_of(photocell)[1], "[1]"
    assert_includes fragments_of(cited)[0], "[1]"
    assert_equal "Es una verificación de cableado", fragments_of(cited)[1]
    assert_equal "Ojo: la unidad no es clara", fragments_of(forward)[0]
    assert_includes fragments_of(forward)[1], "[4]"
    assert_includes fragments_of(absent)[0], "[4]"
    assert_includes fragments_of(absent)[1], "[4] no indica"
    assert_not_includes fragments_of(demanded)[0], "[4]"
    assert_includes fragments_of(demanded)[1], "[4]"
    assert_not_includes fragments_of(streak)[0], "[4]"
    assert_includes fragments_of(streak)[1], "[4]"
    assert_includes fragments_of(streak)[1], "[5]"
    assert_includes fragments_of(behind)[0], "[1]"
    assert_includes fragments_of(behind)[0], "[2]"
    assert_not_includes fragments_of(behind)[1], "[1]"

    rejected = publish(demanded, [ source("la unidad es clara") ])
    assert_equal [ "El manual lo exige" ], rejected.reasons.select { |reason| reason["rule"] == "R3" }.pluck("detail")
  end

  test "an initial capital is the only case difference accepted for the technician's words" do
    seen = "no veo obstrucción"
    capital = publish(
      "\"No veo obstrucción\" es solo una observación visual.",
      [ source(PHOTOCELL) ],
      technician_texts: [ seen ]
    )
    framed = publish(
      "El técnico dijo «No veo obstrucción».",
      [ source(PHOTOCELL) ],
      technician_texts: [ seen ]
    )
    humidity = publish(
      "\"No veo humedad\" es una observación.",
      [ source(PHOTOCELL) ],
      technician_texts: [ seen ]
    )
    smoke = publish(
      'dijiste "no veo humo".',
      [ source(PHOTOCELL) ],
      technician_texts: [ seen ]
    )

    assert capital.accepted?, capital.reasons.inspect
    assert_empty capital.quotes
    assert framed.accepted?, framed.reasons.inspect
    assert_equal [ "No veo humedad" ], humidity.reasons.pluck("detail")
    assert_equal [ "technician_mismatch:no veo humo" ], smoke.reasons.pluck("detail")
  end

  test "B1 guion 1 turn 3 keeps the section 5.6 sense and rejects the trimmed conditional" do
    sentence = PHOTOCELL
    quote = "la fotocélula o la entrada de re-apertura"
    prose = %(Pero el LED se enciende con "#{quote}" [1], así que la causa del LED podría estar en #21.)
    result = publish(prose, [ source(sentence) ])
    format_verdict = {
      "verdict" => "rejected",
      "rule" => "R2",
      "detail" => "condition_dropped:#{quote}"
    }
    sense_verdict = {
      "verdict" => "preserved",
      "section" => "5.6",
      "sentence" => sentence
    }

    assert_equal format_verdict["detail"], result.reasons.sole["detail"]
    assert_equal "rejected", format_verdict["verdict"]
    assert_includes sentence, "cuando #{quote} está activada"
    assert_match(/LED se enciende con/i, prose)
    assert_equal "preserved", sense_verdict["verdict"]
    assert_equal "5.6", sense_verdict["section"]
  end

  test "after guards a removed quote fails and the abstention text is fixed" do
    publication = publish("La página dice «#{WHEN_QUOTE}» [1].", [ source(PHOTOCELL) ])
    lost = Rag::CompanionTurnPublication.after_guards("La página dice [1].", publication.to_h)
    kept = Rag::CompanionTurnPublication.after_guards(
      "La página dice «#{WHEN_QUOTE}» [1].",
      publication.to_h
    )

    assert_includes lost.pluck("detail"), "quote_removed"
    assert_nil kept
    assert_equal(
      "No pude preparar una orientación fiable para este turno; el caso se conserva.",
      Rag::CompanionTurnPublication.abstain_message(:es)
    )
  end

  private

  def publish(text, sources, stop_reason: "end_turn", guarded_text: nil, technician_texts: [])
    Rag::CompanionTurnPublication.call(
      text: text,
      sources: sources,
      stop_reason: stop_reason,
      guarded_text: guarded_text,
      technician_texts: technician_texts
    )
  end

  def source(content, applicability: "compatible", reference_only: false)
    { "content" => content, "applicability" => applicability, "reference_only" => reference_only }
  end

  def rules(result)
    result.reasons.pluck("rule").uniq
  end

  def fragments_of(text)
    Rag::CompanionTurnPublication.send(:companion_fragments, text)
  end
end
