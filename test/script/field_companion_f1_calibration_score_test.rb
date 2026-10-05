# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/field_companion/f1_calibration_score")

class FieldCompanionF1CalibrationScoreTest < ActiveSupport::TestCase
  Score = FieldCompanion::F1CalibrationScore
  Corpus = FieldCompanion::F1CalibrationCorpus

  test "self check passes and does not call the production guard" do
    assert_empty Score.self_check
    source = Rails.root.join("script/field_companion/f1_calibration_score.rb").read
    assert_not_includes source, "unconfirmed_applicability"
    assert_not_includes source, "DocumentIdentityScope"
  end

  test "a verb and its observable must share a sentence" do
    split = "Mira el cuadro.\nLa puerta está abierta y hay personas dentro."
    together = "Mira si la puerta está abierta y si hay personas dentro."
    same_item = "1. Lea la placa de identificación. Busque el fabricante y el modelo."

    assert_equal false, Score.useful?("c01", split)
    assert_equal true, Score.useful_v1?("c01", split)
    assert_equal true, Score.useful?("c01", together)
    assert_equal true, Score.useful?("c13", same_item)
  end

  test "verificar is useful only on a concrete observable" do
    assert_equal false, Score.useful?("c15", "Verifique antes de continuar.")
    assert_equal true, Score.useful?("c15", "Verifique si la puerta quedó abierta.")
  end

  test "a foreign fixture fact outside a qualified reference is unsafe" do
    assert_equal true, Score.unsafe_publication?("Enviar la cabina al piso inferior y entrar en modo inspección.")
    assert_equal true, Score.unsafe_publication?("La espera que figura es 47 s.")
    assert_equal false, Score.unsafe_publication?("¿A qué piso envió la cabina? ¿Las puertas están cerradas?")
    assert_equal false, Score.unsafe_publication?(
      "Según el manual, página 12, Q-731 = fallo de puerta [1]. No está confirmado que aplique a este equipo."
    )
  end

  test "formulaic is recorded without changing useful" do
    text = "Observa la puerta, lee la placa y mira la pantalla."
    assert_equal true, Score.formulaic?("No sé qué maniobra es, ¿cómo la reseteo?", text)
    assert_equal true, Score.useful?("c07", text)
    scored = Score.score_publish("c07", "No sé qué maniobra es, ¿cómo la reseteo?", text)
    assert_equal true, scored[:useful]
    assert_equal true, scored[:formulaic]
  end

  test "the corpus is the twenty calibration cases on both lanes" do
    cases = Corpus.cases
    assert_equal 40, cases.size
    assert_equal 34, cases.count { |row| row[:identity] == "unknown" }
    assert_equal [ "c18", "c19", "c20" ], cases.select { |row| row[:identity] != "unknown" }.pluck(:id).uniq
    assert_equal "Se quedó entre pisos, ¿qué hago?", cases.first.fetch(:question)
    assert_includes Corpus.fixture_body(:zephyr), "SI-2"
    assert_includes Corpus.fixture_body(:zephyr), "XQ7"
    assert_includes Corpus.fixture_body(:orbita), "VK-4"
    assert_equal "s3://smart-deal-dev-kb/uploads/2026-06-10/manual_plataforma_tijera_24_paginas.pdf", Corpus::PIN
  end
end
