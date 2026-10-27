# frozen_string_literal: true

require "test_helper"

class Rag::ObservationCorrectionTest < ActiveSupport::TestCase
  test "the shared tail keeps the replacement for the wordings that used to drop it" do
    expectations = {
      "En realidad la cabina está cerca de planta 2, no de planta 1." => "la cabina está cerca de planta 2",
      "Me equivoqué: la cabina está cerca de planta 2, no en planta 1." => "la cabina está cerca de planta 2",
      "Corrijo: la cabina está cerca de planta 2 y no en planta 1." => "la cabina está cerca de planta 2",
      "Corrijo: el LED que está apagado es el 5, no el 7." => "el LED que está apagado es el 5"
    }

    expectations.each do |turn, phrase|
      correction = Rag::ObservationCorrection.resolve(turn: turn)

      assert_includes correction.asserted, phrase, turn
      assert correction.retracted.any?, turn
      assert_not correction.retracted.any? { |item| item.include?("lo sé") }, turn
    end
  end

  test "a bare number retracts only the observation that shares the replacement's words" do
    asserted = [ "el LED que está apagado es el 5" ]

    assert Rag::ObservationCorrection.retracted?("El LED 7 está apagado", "7", asserted)
    assert_not Rag::ObservationCorrection.retracted?("El código 18 sigue", "7", asserted)
    assert_not Rag::ObservationCorrection.retracted?("el LED que está apagado es el 5", "7", asserted)
  end

  test "an explicit cue and a bare state contrast retracts that state" do
    turn = "Corrijo un dato: el LED de fotocélula está encendido, no apagado. Lo demás se mantiene."
    correction = Rag::ObservationCorrection.resolve(
      turn: turn,
      assertions: [ { "span" => "el LED de fotocélula está encendido", "act" => "assert" } ]
    )

    assert_includes correction.asserted, "el LED de fotocélula está encendido"
    assert_includes correction.retracted, "apagado"
    assert correction.retracted.none? { |item| item.include?("mantiene") }
  end

  test "a bare state contrast without a correction cue is not a retraction" do
    correction = Rag::ObservationCorrection.resolve(turn: "El indicador está encendido, no apagado.")

    assert_empty correction.asserted
    assert_empty correction.retracted
  end

  test "the complete generic led observation is encendido and retracts apagado" do
    phrase = "el LED está encendido, no apagado"
    correction = Rag::ObservationCorrection.resolve(
      turn: "orrijo un dato: #{phrase}.",
      observations: [ phrase ],
      assertions: [ { "span" => "el LED está encendido", "act" => "assert" } ]
    )

    assert_equal "encendido", Rag::ObservationCorrection.led_state(phrase)
    assert_equal [ "el LED está encendido" ], correction.asserted
    assert_equal [ "apagado" ], correction.retracted
  end

  test "a led contrast keeps a qualified led, a hedge, and a different indicator apart" do
    qualified = "el LED de fotocélula está encendido, no apagado"
    contrast = Rag::ObservationCorrection.led_contrast(qualified)

    assert_equal "el LED de fotocélula está encendido", contrast.head
    assert_equal "encendido", contrast.state
    assert_nil Rag::ObservationCorrection.led_state("el LED está encendido, no sé")
    assert_nil Rag::ObservationCorrection.led_state("el LED está encendido, no estoy seguro")
    assert_nil Rag::ObservationCorrection.led_state("el LED de fotocélula está encendido, no el de estado")
    assert_nil Rag::ObservationCorrection.led_state("el LED que está apagado es el 5, no el 7")
    assert_nil Rag::ObservationCorrection.led_contrast("el LED está encendido, no encendido")

    indicator = Rag::ObservationCorrection.resolve(
      turn: "El indicador está encendido, no apagado.",
      observations: [ "El indicador está encendido, no apagado." ]
    )
    assert_empty indicator.asserted
    assert_empty indicator.retracted
  end

  test "a generic led contrast does not choose between two different leds" do
    stored = [
      { "text" => "El LED de fotocélula está apagado" },
      { "text" => "El LED de estado está apagado" }
    ]
    correction = Rag::ObservationCorrection.resolve(
      turn: "orrijo un dato: el LED está encendido, no apagado.",
      observations: [ "el LED está encendido, no apagado" ]
    )

    assert_equal :ambiguous, Rag::ObservationCorrection.targets(stored, correction)
  end

  test "a report that contrasts two actions without a cue is not a retraction" do
    correction = Rag::ObservationCorrection.resolve(turn: "La puerta llega al marco, no retiene el imán.")

    assert_empty correction.asserted
    assert_empty correction.retracted
  end

  test "several matching observations stay ambiguous until the replacement names one" do
    stored = [
      { "text" => "el sensor de puerta está apagado" },
      { "text" => "el indicador de piso está apagado" }
    ]
    vague = Rag::ObservationCorrection.resolve(turn: "Corrijo un dato: está encendido, no apagado.")
    named = Rag::ObservationCorrection.resolve(turn: "Corrijo: el sensor de puerta está encendido, no apagado.")

    assert_equal :ambiguous, Rag::ObservationCorrection.targets(stored, vague)
    assert_equal [ "el sensor de puerta está apagado" ], Rag::ObservationCorrection.targets(stored, named)
  end

  test "a turn without a retractive tail is not a correction" do
    correction = Rag::ObservationCorrection.resolve(turn: "No veo una obstrucción en la guía.")

    assert_empty correction.asserted
    assert_empty correction.retracted
  end

  test "a negated pronoun or copula inside a report is not a retraction" do
    [
      "La puerta de cabina no la cierra el operador.",
      "El operador abre la puerta pero no la termina de cerrar.",
      "Revisé los contactos de puerta y no los veo sucios.",
      "El variador enciende pero el motor no es el que hace ruido.",
      "La puerta llega al marco, no la retiene el imán."
    ].each do |turn|
      assert_not Rag::ObservationCorrection.resolve(turn: turn, observations: [ turn.delete_suffix(".") ]).active?, turn
    end
  end

  test "a parallel contrast is a correction without an explicit cue" do
    correction = Rag::ObservationCorrection.resolve(turn: "La cabina queda cerca de planta 2, no de planta 1.")

    assert_equal [ "La cabina queda cerca de planta 2" ], correction.asserted
    assert_equal [ "planta 1" ], correction.retracted
  end
end
