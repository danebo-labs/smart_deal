# frozen_string_literal: true

require "test_helper"

class Rag::JourneyAMessagesTest < ActiveSupport::TestCase
  ORIGIN = "Escuche el sonido del clic cuando se ordena el cierre. ¿El ruido proviene del imán o del mecanismo de cierre de la puerta?"

  test "a code correction keeps its own text when the previous question was about the click" do
    sent, notes, = Rag::JourneyAMessages.adapt(
      turn_number: 5,
      original: "No, leí mal: era código 18, no 8.",
      previous_answer: ORIGIN
    )

    assert_equal "No, leí mal: era código 18, no 8. No lo sé.", sent
    assert_equal [ "unknown" ], notes
    assert_not_includes sent, "guía"
    assert_not_includes sent, "oye un clic"
  end

  test "the guide turn is not prefixed with the click" do
    original = "Ya comprobé visualmente la guía de la puerta; no veo una obstrucción."
    sent, notes, = Rag::JourneyAMessages.adapt(
      turn_number: 6,
      original: original,
      previous_answer: ORIGIN
    )

    assert_equal "#{original} No lo sé.", sent
    assert_equal [ "unknown" ], notes
    assert_not_includes sent, "Al pedir cierre"
  end

  test "sigue igual does not receive a click fact, and an origin question stays unknown" do
    sent, notes, = Rag::JourneyAMessages.adapt(
      turn_number: 12,
      original: "Sigue igual.",
      previous_answer: "Escucha el sonido del clic cuando pides cierre. ¿Proviene del motor de la puerta, del pestillo o de otra zona del marco?"
    )

    assert_equal "Sigue igual. No lo sé.", sent
    assert_equal [ "unknown" ], notes
    assert_not_includes sent, "motor"
    assert_not_includes sent, "pestillo"
  end

  test "an already reported click is not answered again by inventing its origin" do
    original = "Al pedir cierre se oye un clic, pero no termina de cerrar."
    sent, notes, = Rag::JourneyAMessages.adapt(
      turn_number: 8,
      original: original,
      previous_answer: "¿Oyes un clic al pedir el cierre?"
    )

    assert_equal original, sent
    assert_empty notes
  end

  test "a later fact is not pulled onto an earlier turn" do
    sent, = Rag::JourneyAMessages.adapt(
      turn_number: 5,
      original: "No, leí mal: era código 18, no 8.",
      previous_answer: "¿Hay personas dentro? ¿En qué planta está detenida?"
    )

    assert_equal "No, leí mal: era código 18, no 8.", sent
    assert_not_includes sent, "planta"
    assert_not_includes sent, "personas"
  end

  test "turn 11 keeps its click fact when Danebo did not name a review" do
    sent, notes, = Rag::JourneyAMessages.adapt(
      turn_number: 11,
      original: "Hice esa revisión: sigue el clic y la puerta no termina de cerrar.",
      previous_answer: "Puedes seguir con lo que ya me contaste."
    )

    assert_equal "Sigue el clic y la puerta no termina de cerrar.", sent
    assert_equal [ "spontaneous_click" ], notes
  end
end
