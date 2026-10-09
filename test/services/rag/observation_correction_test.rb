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

  test "a turn without a retractive tail is not a correction" do
    correction = Rag::ObservationCorrection.resolve(turn: "No veo una obstrucción en la guía.")

    assert_empty correction.asserted
    assert_empty correction.retracted
  end
end
