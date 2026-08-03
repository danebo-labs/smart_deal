# frozen_string_literal: true

require "test_helper"
require "json"

# QA de la Fase 0b del plan quirúrgico (docs/rag/plan_quirurgico_precision_2026-08-02.md):
# antes de congelar script/fixtures/rag_seguridades_holdout_v2.json, cada patrón `penalized`
# se prueba contra al menos una respuesta correcta conocida, con el evaluador real
# (regex puro, $0, sin Bedrock). El holdout v1 mostró dos falsos positivos de rúbrica por
# ventanas `.{0,N}` que cruzaban ítems de una lista y por un lookahead de negación que no
# cubría el "no" pospuesto; este test evita ambos defectos y los deja bajo regresión.
class Rag::BenchmarkRubricEvaluatorHoldoutV2QaTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("script/fixtures/rag_seguridades_holdout_v2.json")

  KNOWN_CORRECT_ANSWERS = {
    "holdout_v2_aljo_altius_d12_d13" =>
      "En ALJO ALTIUS, el LED D12 corresponde a SERIE CERRADURAS EXTERIORES y el LED D13 " \
      "corresponde a SERIE SEGURIDAD PUERTAS EXTERIORES.",
    "holdout_v2_edel_k2_36c_41" =>
      "En EDEL-K2, el LED 36C corresponde a SERIE SEGURIDADES CABINA y el LED 41 " \
      "corresponde a SERIE CERROJOS CABINA.",
    "holdout_v2_aljo_control_level1b_dl3_dl4" =>
      "En ALJO CONTROL LEVEL 1B, el LED DL3 corresponde a SERIE PUERTAS CERRRADA y el LED " \
      "DL4 corresponde a SERIE SEGURIDADES CERRADA.",
    "holdout_v2_schindler_divisor_modelos" =>
      "La página divisoria de SCHINDLER lista los modelos MICONIC LX, SMART 001 CRIPS, " \
      "SMART 001, MICONIC BX - 6200, BIONIC 5 REL.2 - 3300 y BIONIC 5 REL.4 - 3300.",
    "holdout_v2_orona_divisor_arca" =>
      "El modelo ARCA III pertenece a la marca ORONA. Su página divisoria también lista " \
      "ARCA, ARCA BASICO y ARCA II.",
    "holdout_v2_carlos_silva_xp11_intermedios" =>
      "El conductor que llega a XP11 desde STOP BOTO. CABINA pasa antes por BOTONERA " \
      "REVISION y por BARANDILLA.",
    "holdout_v2_cta_mr08_sci_fotocelula" =>
      "El LED SCI documenta SERIE OBSTACULO, referida a los conectores CN-112 (pin SC) y " \
      "CN-109 (pin CC). Además, el cable entre OBSTACULO y CN-112 pasa por FOTOCELULA antes " \
      "de llegar, un dispositivo intermedio que la arista no nombra.",
    "holdout_v2_schindler_isk_ambiguous" =>
      "En SCHINDLER el LED ISK no tiene un único significado: depende del modelo. En " \
      "SMART 001 (variante CRIPS), ISK indica SERIE SEGURIDADES CCERRADA; en cambio en " \
      "MICONIC BX y BIONIC 5, ISK indica SERIE SEGURDADES CERRADA (KSS.1-SEM.6).",
    "holdout_v2_miconic_lx_t6_absent" =>
      "El documento no incluye este dato: SCHINDLER MICONIC LX no documenta el LED T6 en " \
      "su tabla de LEDs.",
    "holdout_v2_arca3_bypass_j25_seguridad" =>
      "Con el puente en posición J25, el ARCA III entra en modo de revisión con las " \
      "cerraduras de cabina puenteadas; a diferencia de J24 (que puentea las seguridades " \
      "de cabina) o J26 (que puentea las cerraduras exteriores), este puente limita el " \
      "bypass a la cabina."
  }.freeze

  setup do
    @rubric = JSON.parse(File.read(FIXTURE_PATH))
  end

  test "fixture has the 10-question stratified distribution from Fase 0b" do
    strata = @rubric.fetch("cases").map { |c| c.fetch("stratum") }
    assert_equal 10, strata.size

    assert_equal(
      {
        "deterministica" => 3,
        "mapeo_estructurado" => 2,
        "generalizacion" => 2,
        "ambigua" => 1,
        "sin_respaldo" => 1,
        "seguridad" => 1
      },
      strata.tally
    )
  end

  test "real max_score sums to 88 (max_score/passing_score fields are documental only)" do
    total = @rubric.fetch("cases").sum do |c|
      c.fetch("required").size * 2 + c.fetch("optional").size + (@rubric.fetch("citation_required") ? 2 : 0)
    end

    assert_equal 88, total
    assert_equal 88, @rubric.fetch("max_score"), "documental max_score drifted from the real evaluator sum"
    assert_equal 70, @rubric.fetch("passing_score")
  end

  test "every case has a known-correct answer covering this QA" do
    ids = @rubric.fetch("cases").map { |c| c.fetch("id") }
    assert_equal ids.sort, KNOWN_CORRECT_ANSWERS.keys.sort
  end

  test "each penalized pattern does not fire on a known-correct answer, and required/citation pass" do
    @rubric.fetch("cases").each do |definition|
      id = definition.fetch("id")
      answer = KNOWN_CORRECT_ANSWERS.fetch(id)

      payload = {
        "run_id" => "qa-holdout-v2",
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
