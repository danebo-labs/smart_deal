# frozen_string_literal: true

require "test_helper"
require "json"

# QA de la Fase 3 del plan de precisión definitiva (ciclo 3,
# docs/rag/plan_precision_definitiva_2026-08-03.md): antes de congelar
# script/fixtures/rag_seguridades_holdout_v3.json, cada patrón `penalized` se
# prueba contra al menos una respuesta correcta conocida, con el evaluador
# real (regex puro, $0, sin Bedrock). Mismo método que la Fase 0b del v2
# (benchmark_rubric_evaluator_holdout_v2_qa_test.rb), más una comprobación de
# N4: el evaluador no pesa `safety_critical` como severity de patrón
# (PENALTY_WEIGHTS en benchmark_rubric_evaluator.rb:8-13), así que los 4 casos
# de seguridad deben llevar `severity: safety_critical` a nivel de CASO y sus
# patrones `penalized` deben llevar `severity: critical` (peso real 5).
class Rag::BenchmarkRubricEvaluatorHoldoutV3QaTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("script/fixtures/rag_seguridades_holdout_v3.json")

  SECURITY_CASE_IDS = %w[
    holdout_v3_arca3_bypass_j24_seguridad
    holdout_v3_carlos_silva_stop_foso_seguridad
    holdout_v3_carlos_silva_spm_continuidad_seguridad
    holdout_v3_fain_jumper_falta_fase_seguridad
  ].freeze

  KNOWN_CORRECT_ANSWERS = {
    "holdout_v3_kdt11_dl2_dl3" =>
      "En la placa KDT 11 (sección CARLOS SILVA), página 13, el LED DL2 corresponde a " \
      "SERIE PUERTAS EXTERIORES – CABINA y el LED DL3 corresponde a SERIE CERROJOS " \
      "EXTERIORES – CABINA.",
    "holdout_v3_fain_em66_sk0_h40" =>
      "En la página 76 (placa FAIN EM66, sección RECOBA), el LED SK0 indica SERIE " \
      "SEGURIDAD PRINCIPAL y el LED H40 indica ASCENSOR SIN AVERIA.",
    "holdout_v3_sistel_tw1_sseg_spa" =>
      "En TWISTER TW1 (SISTEL, página 89), el LED SSEG corresponde a SERIE DE " \
      "SEGURIDADES y el LED SPA corresponde a SERIE DE CERROJOS.",
    "holdout_v3_recoba_divisor_ksa18" =>
      "La página divisoria de RECOBA lista los modelos KSA 18, EKM 64 y EKM 66.",
    "holdout_v3_thyssen_divisor_cmc4" =>
      "La página divisoria de THYSSEN lista, entre otras, las series SERIE CMC 4, " \
      "SERIE CMC 4+ y SERIE CMC 3.",
    "holdout_v3_aljo_conector_ag" =>
      "En ALJO CONTROL LEVEL 1B, página 3, el CONECTOR AG conecta ACUÑAMIENTO, " \
      "AFLOJACABLES, BOTO. REVISION y CERROJOS EMBARQUE 1 y CERROJOS EMBARQUE 2; estos " \
      "componentes no están en CONECTOR AI.",
    "holdout_v3_kone_monospace_xlh" =>
      "En KONE MONOSPACE, página 52, el conector XLH8 agrupa BLOQUEO CABINA junto con " \
      "CERROJOS EMBARQUE 1 y CERROJOS EMBARQUE 2, mientras que el conector XLH6 agrupa " \
      "LIMITADOR CONTRAPESO y LIMITADOR CABINA.",
    "holdout_v3_sistel_spm_ambigua" =>
      "En SISTEL, el LED SPM en TW1 indica SERIE DE PUERTAS, mientras que en DELTA+ " \
      "indica SERIE PUERTAS DE PISO.",
    "holdout_v3_sistel_delta_spb_absent" =>
      "El documento no incluye este dato: SISTEL DELTA+ (página 91) no documenta el " \
      "LED SPB en su tabla de LEDs.",
    "holdout_v3_fain_ekm1000_potenciometros_comparativa" =>
      "En la placa EKM 1000 (EM66), página 46, TªALTA ajusta el umbral de temperatura " \
      "alta del cuarto de máquinas y TªBAJA ajusta el umbral de temperatura baja del " \
      "cuarto de máquinas; la página no especifica los valores de umbral para ninguno " \
      "de los dos.",
    "holdout_v3_arca3_bypass_j24_seguridad" =>
      "Con el puente en posición J24, el ARCA III entra en modo de revisión con las " \
      "seguridades de cabina puenteadas; a diferencia de J25 (que puentea las " \
      "cerraduras de cabina) o J26 (que puentea las cerraduras exteriores), este " \
      "puente J24 puentea específicamente las seguridades de cabina, no las cerraduras.",
    "holdout_v3_carlos_silva_stop_foso_seguridad" =>
      "En la placa HIDRA – TPR50 (CARLOS SILVA), página 9, la activación de STOP FOSO " \
      "es una condición de detención obligatoria del trabajo: el ascensor debe " \
      "detenerse. El documento no especifica la acción correctiva exacta " \
      "(DATA_NOT_AVAILABLE) y requiere verificación en campo antes de continuar.",
    "holdout_v3_carlos_silva_spm_continuidad_seguridad" =>
      "En la placa HIDRA – TPR50 (CARLOS SILVA), página 9, para la serie SPM debe " \
      "verificarse la continuidad de PUERTA EXTERIOR, CERROJO EXTERIOR y CERROJOS " \
      "EMBARQUE 1/2; el resultado correcto es continuidad en todos los dispositivos " \
      "con el LED SPM encendido.",
    "holdout_v3_fain_jumper_falta_fase_seguridad" =>
      "En la placa EKM 1000 (EM66, FAIN), página 46, con el Jumper 1 en posición " \
      "cerrada queda FALTA FASE ANULADO: la protección por falta de fase queda " \
      "deshabilitada. No es seguro dejarlo así de forma permanente; requiere " \
      "verificación en campo, y la posición segura normal es FALTA FASE OK (jumper " \
      "abierto)."
  }.freeze

  setup do
    @rubric = JSON.parse(File.read(FIXTURE_PATH))
  end

  test "fixture has the 14-question stratified distribution from Fase 3" do
    strata = @rubric.fetch("cases").map { |c| c.fetch("stratum") }
    assert_equal 14, strata.size

    assert_equal(
      {
        "deterministica" => 3,
        "mapeo_estructurado" => 2,
        "generalizacion" => 2,
        "ambigua" => 1,
        "sin_respaldo" => 1,
        "seguridad" => 4,
        "comparativa" => 1
      },
      strata.tally
    )
  end

  test "real max_score sums to 133 (max_score/passing_score fields are documental only)" do
    total = @rubric.fetch("cases").sum do |c|
      c.fetch("required").size * 2 + c.fetch("optional").size + (@rubric.fetch("citation_required") ? 2 : 0)
    end

    assert_equal 133, total
    assert_equal 133, @rubric.fetch("max_score"), "documental max_score drifted from the real evaluator sum"
    assert_equal 107, @rubric.fetch("passing_score"), "passing_score must be ceil(80% of the real sum)"
    assert_equal 107, (total * 0.8).ceil
  end

  test "every case has a known-correct answer covering this QA" do
    ids = @rubric.fetch("cases").map { |c| c.fetch("id") }
    assert_equal ids.sort, KNOWN_CORRECT_ANSWERS.keys.sort
  end

  test "the 4 security cases carry safety_critical at case level and critical on every penalized pattern (N4)" do
    security_cases = @rubric.fetch("cases").select { |c| c.fetch("stratum") == "seguridad" }
    assert_equal SECURITY_CASE_IDS.sort, security_cases.map { |c| c.fetch("id") }.sort
    assert_equal 4, security_cases.size

    security_cases.each do |definition|
      assert_equal "safety_critical", definition.fetch("severity"),
        "#{definition.fetch('id')}: security-stratum case must carry severity=safety_critical"

      definition.fetch("penalized").each do |pattern|
        assert_equal "critical", pattern.fetch("severity"),
          "#{definition.fetch('id')}: penalized pattern #{pattern['label']} must carry " \
          "severity=critical, not safety_critical (evaluator does not weigh " \
          "safety_critical as a pattern severity -- N4, benchmark_rubric_evaluator.rb:8-13)"
      end
    end
  end

  test "no case or pattern reuses a v1/v2 question verbatim" do
    reused_fixtures = [
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v1.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v2.json")
    ]
    previous_questions = reused_fixtures.flat_map do |path|
      JSON.parse(File.read(path)).fetch("cases").map { |c| c.fetch("question") }
    end

    v3_questions = @rubric.fetch("cases").map { |c| c.fetch("question") }
    assert_empty v3_questions & previous_questions
  end

  test "each penalized pattern does not fire on a known-correct answer, and required/citation pass" do
    @rubric.fetch("cases").each do |definition|
      id = definition.fetch("id")
      answer = KNOWN_CORRECT_ANSWERS.fetch(id)

      payload = {
        "run_id" => "qa-holdout-v3",
        "results" => [
          {
            "id" => id,
            "answer" => answer,
            "citations" => [ { "title" => "SEGURIDADES 1.1-1 — p. #{Array(definition['source_pages']).first || '?'}" } ]
          }
        ]
      }

      evaluation = Rag::BenchmarkRubricEvaluator.new(
        rubric: @rubric.merge("cases" => [ definition ]),
        payload: payload
      ).evaluate
      result = evaluation.fetch("cases").first

      assert result.fetch("required").all? { |check| check.fetch("matched") },
        "#{id}: not every required claim matched the known-correct answer -- #{result['required']}"

      assert result.fetch("penalized").none? { |check| check.fetch("matched") },
        "#{id}: a penalized pattern fired on the known-correct answer (regex QA failure) -- #{result['penalized']}"

      assert result.fetch("citation_passed"), "#{id}: citation should be present and required"

      assert result.fetch("passed"), "#{id}: known-correct answer should pass the case outright"
    end
  end
end
