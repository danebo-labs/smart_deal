# frozen_string_literal: true

require "test_helper"
require "json"

# QA offline de script/fixtures/pilot_release_precision_battery_rubric.json
# (Paso 6, docs/PLAN_LIBERACION_PILOTO_2026-08-25.md): antes de gastar crédito
# real en la corrida única, cada uno de los 20 casos se prueba contra una
# respuesta correcta conocida (grounded en el evidence_note real de
# script/fixtures/pilot_release_precision_battery_questions.json, no
# inventada) y contra una respuesta incorrecta plausible que debe disparar su
# `penalized`. Evaluador real (Rag::BenchmarkRubricEvaluator, sin modificar),
# regex puro, $0, sin Bedrock. Mismo patrón que
# holdout_v6_sonda_qa_test.rb/benchmark_rubric_evaluator_holdout_v5_qa_test.rb.
class PilotReleasePrecisionBatteryRubricQaTest < ActiveSupport::TestCase
  RUBRIC_PATH = Rails.root.join("script/fixtures/pilot_release_precision_battery_rubric.json")

  KNOWN_CORRECT = {
    "blt_01" => "El PLC Omron del escalador BLT documenta señales de entrada como el " \
      "monitor de pasamanos (handrail monitor), el guardapiés (skirt) y la cadena " \
      "de tracción (drive chain).",
    "blt_02" => "El PLC BLT-ES output documenta las salidas Y0 a Y17, que accionan " \
      "contactores desde 6KM1 hasta 6KM8.",
    "blt_03" => "Los conectores QS identifican cada punto con un código como XP2, y " \
      "cada pin de esa tabla corresponde a una señal específica.",
    "blt_04" => "El rodillo de la cadena de tracción del motor debe tener una holgura " \
      "de 2 mm.",
    "blt_06" => "El código E12 indica Error de Inverter; el método de reanudación es " \
      "conectar monitor y revisar o resetear la falla.",
    "fuji_yida_02" => "El código Er19 se genera cuando la distancia de desaceleración " \
      "no es suficiente; la primera solución es disminuir el parámetro Least Speed " \
      "en el menú de usuario.",
    "fuji_yida_04" => "El pin J1-3 corresponde a CAN Bus H y el pin J1-4 a CAN Bus L.",
    "kone_01" => "El código 104 (Motor Protection) agrupa la protección del motor; su " \
      "subcódigo 2003 se registra cuando el termistor del motor está sobrecalentado " \
      "o el cable del termistor está desconectado.",
    "kone_03" => "Las cuerdas del regulador de velocidad (overspeed governor) no " \
      "deben lubricarse nunca, según la advertencia del manual.",
    "kone_08" => "El código 0126 corresponde al relé de seguridad conectado en XSR1 " \
      "quedando abierto; se recomienda revisar las conexiones de XSR1 y el panel de " \
      "control.",
    "kone_10" => "El factor KTC para las variantes G01, G02, G09 y G18 es 121.1 Nm/A.",
    "mitsubishi_03" => "Antes de la medición de resistencia de aislamiento deben " \
      "desconectarse los conectores RPJ y RPW.",
    "mitsubishi_10" => "Cuando se proveen amortiguadores de resorte, los interruptores " \
      "UOT y DOT deben ajustarse para operar antes de que los amortiguadores entren " \
      "en contacto.",
    "otis_04" => "Se debe usar el kit VSP028 y una broca de 9/32 pulgadas para hacer " \
      "los nuevos orificios.",
    "otis_08" => "El valor nominal de la resistencia WBR para el VF30BR es 20 ohms, y " \
      "la lectura del multímetro debe estar entre 18 y 22 ohms para considerarla " \
      "correcta.",
    "otis_10" => "El error número 16 corresponde a Overtemp HS Trigger (HW) y se " \
      "muestra como OVERT HSTrig en la pantalla SMLCD.",
    "tke_03" => "El sistema genera el código E140; apaga el motor y permanece 10 " \
      "segundos en estado Blq antes de pasar a Ini.",
    "tke_05" => "El termostato es de la unidad IGBT y el relé térmico es de los " \
      "resistores de frenado; el MCINV verifica los 24V en el punto 101.",
    "tke_07" => "El código hB indica que el dispositivo Flash M25P40 no funciona " \
      "correctamente; contiene información de validación del módulo por el " \
      "proveedor.",
    "tke_09" => "El conector X13 queda como el único utilizado para Teleservicio, y " \
      "el conector X12 de la generación anterior desaparece."
  }.freeze

  # Respuesta plausible pero incorrecta, diseñada para disparar el `penalized`
  # de cada caso — no se le exige pasar `required`, sólo probar que el
  # penalized funciona (no está inerte) sobre un error real y verificable.
  # blt_01 no tiene penalized (se retiró tras la Fase 2.5: 6KM1 aparece
  # legítimamente en la propia sección de cadena de seguridad de ESTE
  # documento, no sólo en el de salidas — un falso positivo real que la
  # verificación contra chunks reales encontró), así que no participa aquí.
  KNOWN_INCORRECT_TRIGGERS_PENALIZED = {
    "blt_02" => "El PLC BLT-ES output documenta las salidas Y0 a Y17, información " \
      "que proviene del mismo diagrama Omron de entradas X0.",
    "blt_03" => "Los conectores QS no documentan pines ni señales en sus tablas.",
    "blt_04" => "El rodillo de la cadena de tracción del motor debe tener una " \
      "holgura de 3 mm.",
    "blt_06" => "El código E12 indica Error de Inverter; el método de reanudación " \
      "es el cierre de contacto de puerta.",
    "fuji_yida_02" => "El código Er19 se genera cuando la distancia de " \
      "desaceleración no es suficiente; la solución es incrementar la ganancia PI " \
      "del controlador.",
    "fuji_yida_04" => "El pin J1-3 corresponde a CAN Bus L y el pin J1-4 a CAN Bus H.",
    "kone_01" => "El código 103 documenta el termistor del motor sobrecalentado.",
    "kone_03" => "Las cuerdas del regulador de velocidad sí deben lubricarse " \
      "periódicamente.",
    "kone_08" => "El código 0127 corresponde al relé de seguridad conectado en " \
      "XSR1 quedando abierto (contactor principal).",
    "kone_10" => "El factor KTC para las variantes G01, G02, G09 y G18 es 100.6 Nm/A.",
    "mitsubishi_03" => "No es necesario desconectar los conectores RPJ y RPW antes " \
      "de la medición de resistencia de aislamiento.",
    "mitsubishi_10" => "Cuando se proveen amortiguadores de resorte, los " \
      "interruptores UOT y DOT deben ajustarse para operar después de que los " \
      "amortiguadores entren en contacto.",
    "otis_04" => "Se debe usar el kit e-QUAL-002 y una broca de 9/32 pulgadas.",
    "otis_08" => "El valor nominal de la resistencia WBR para el VF30BR es 12,5 ohms.",
    "otis_10" => "El error número 16 se muestra como OVERT HS Lim en la pantalla " \
      "SMLCD.",
    "tke_03" => "El sistema genera el código A141 en esa condición.",
    "tke_05" => "El MCINV verifica los 24V en el punto T24+ para este error.",
    "tke_07" => "El código hA indica que el módulo no fue testeado por el " \
      "proveedor.",
    "tke_09" => "El conector X22 es el único utilizado para Teleservicio en la " \
      "nueva maniobra."
  }.freeze

  setup do
    @rubric = JSON.parse(File.read(RUBRIC_PATH))
  end

  test "rubric fixture has exactly the 20 cases this test covers" do
    ids = @rubric.fetch("cases").map { |c| c.fetch("id") }
    assert_equal 20, ids.size
    assert_equal ids.sort, KNOWN_CORRECT.keys.sort

    # Sólo los casos con al menos un penalized declarado deben tener una
    # respuesta incorrecta conocida que lo dispare (blt_01 no tiene ninguno).
    ids_with_penalized = @rubric.fetch("cases").select { |c| c.fetch("penalized").any? }.map { |c| c.fetch("id") }
    assert_equal ids_with_penalized.sort, KNOWN_INCORRECT_TRIGGERS_PENALIZED.keys.sort
  end

  test "known-correct answers satisfy all required checks, trip no penalized check, and pass" do
    KNOWN_CORRECT.each do |id, answer|
      definition = @rubric.fetch("cases").find { |c| c.fetch("id") == id }
      evaluation = evaluate_single(definition, id, answer)
      result = evaluation.fetch("cases").first

      assert result.fetch("required").all? { |check| check.fetch("matched") },
        "#{id}: no todos los required coinciden con la respuesta conocida — #{result['required']}"
      assert result.fetch("penalized").none? { |check| check.fetch("matched") },
        "#{id}: un penalized disparó sobre la respuesta correcta conocida (falso positivo) — #{result['penalized']}"
      assert result.fetch("citation_passed"), "#{id}: debe tener citación presente"
      assert result.fetch("passed"), "#{id}: la respuesta conocida correcta debe pasar el caso"
    end
  end

  test "known-incorrect answers trip the penalized check they were designed to catch" do
    KNOWN_INCORRECT_TRIGGERS_PENALIZED.each do |id, answer|
      definition = @rubric.fetch("cases").find { |c| c.fetch("id") == id }
      evaluation = evaluate_single(definition, id, answer)
      result = evaluation.fetch("cases").first

      assert result.fetch("penalized").any? { |check| check.fetch("matched") },
        "#{id}: la respuesta incorrecta conocida NO disparó ningún penalized (regex inerte) — #{result['penalized']}"
      assert_not result.fetch("passed"), "#{id}: una respuesta con un penalized disparado nunca debe pasar"
    end
  end

  test "every case has source_page_required false (cross-document risk at account scope, not single-document)" do
    @rubric.fetch("cases").each do |definition|
      assert_equal false, definition.fetch("source_page_required"),
        "#{definition.fetch('id')}: source_page_matches? no verifica identidad de documento — " \
        "a nivel de cuenta (6 marcas) exigir página puede dar falsos positivos/negativos entre documentos distintos"
    end
  end

  test "citation_required defaults to true at the rubric level" do
    assert_equal true, @rubric.fetch("citation_required")
  end

  private

  def evaluate_single(definition, id, answer)
    payload = {
      "run_id" => "qa-pilot-release-precision-battery",
      "results" => [ { "id" => id, "answer" => answer, "citations" => [ { "title" => "manual — citación" } ] } ]
    }
    Rag::BenchmarkRubricEvaluator.new(
      rubric: @rubric.merge("cases" => [ definition ]),
      payload: payload
    ).evaluate
  end
end
