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

    assert_not attributed.accepted?
    assert_equal [ "R3" ], rules(attributed)
    assert absence.accepted?, absence.reasons.inspect
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
end
