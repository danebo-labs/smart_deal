# frozen_string_literal: true

require "test_helper"
require "json"

# QA de la Fase 5 del ciclo 4 (docs/rag/plan_ciclo4_ajuste_final_2026-08-03.md):
# antes de congelar script/fixtures/rag_seguridades_holdout_v4.json, cada
# patrón `penalized` se prueba contra al menos una respuesta correcta
# conocida, con el evaluador real (regex puro, $0, sin Bedrock). Clonado de
# benchmark_rubric_evaluator_holdout_v3_qa_test.rb, con dos verificaciones
# nuevas propias del v4: (1) el evaluador v2 (Fase 4) expone
# `source_page_cited`/`source_page_required` por caso -- se verifica que la
# respuesta correcta conocida cite una página dentro de `source_pages`; (2)
# los 4 casos de seguridad siguen llevando `severity: safety_critical` a
# nivel de CASO y `severity: critical` en cada `penalized` (N4, el evaluador
# no pesa `safety_critical` como severity de patrón).
class Rag::BenchmarkRubricEvaluatorHoldoutV4QaTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("script/fixtures/rag_seguridades_holdout_v4.json")

  SECURITY_CASE_IDS = %w[
    holdout_v4_fain_ekm1000_jumper_abierto_seguridad
    holdout_v4_arca3_bypass_j26_seguridad
    holdout_v4_carlos_silva_tpr70_b7_seguridad
    holdout_v4_thyssen_cmc4_cn26_seguridad
  ].freeze

  KNOWN_CORRECT_ANSWERS = {
    "holdout_v4_thyssen_cmc4_seg_encl" =>
      "En la placa CMC4 (THYSSEN, página 97), el LED SEG corresponde a SERIE " \
      "SEGURIDADES PRINCIPALES y el LED ENCL corresponde a SERIE CERROJOS " \
      "EXTERIORES - CABINA.",
    "holdout_v4_inelca_homelift_sc3_sc4" =>
      "En la placa HOMELIFT (sección INELCA), página 50, el LED SC3 corresponde " \
      "a SERIE SEGURIDAD EXTERIORES - CABINA y el LED SC4 corresponde a SERIE " \
      "SEGURIDAD STOP - BARRERA CABINA.",
    "holdout_v4_mp_mac5000_dl21_dl45" =>
      "En la placa MAC 5000 (sección MP), página 55, el LED DL21 corresponde a " \
      "SERIE PUERTAS CERRADA y el LED DL45 corresponde a SERIE CERROJOS CERRADA.",
    "holdout_v4_thyssen_divisor_series_ebf" =>
      "La página divisoria de THYSSEN (página 92) lista, además de las series " \
      "CMC, las series SERIE E, SERIE B y SERIE F.",
    "holdout_v4_fain_recoba_stopfoso_c101" =>
      "En la página 78 (placa FAIN EM66 ELECTRICO, sección RECOBA), STOP FOSO " \
      "está conectado al bloque de bornes C101, no a C200B.",
    "holdout_v4_aljo_conector_ai" =>
      "En ALJO CONTROL LEVEL 1B, página 3, el CONECTOR AI conecta STOP FOSO, " \
      "LIMITADOR, POLEA TENSORA, FINALES, CERROJOS EXTERIORES y PUERTAS " \
      "EXTERIORES; estos componentes no están en CONECTOR AG.",
    "holdout_v4_fain_recoba_presostato_c304" =>
      "En la página 77 (placa FAIN EM66 HIDRAULCO, sección RECOBA), el " \
      "PRESOSTATO está conectado al bloque C304 (terminales V10, V11) y es un " \
      "contacto (NC).",
    "holdout_v4_orona_arca_p32_ambigua" =>
      "En ORONA, el LED P32 en la placa ARCA (básica) corresponde a SERIE " \
      "CERROJOS CABINA - EXTERIORES, mientras que en ARCA III el LED P32 " \
      "corresponde a SERIE SEGURIDADES PRINCIPALES -- no es la misma serie en " \
      "ambas placas.",
    "holdout_v4_arca3_bypass_puntos_sin_respaldo" =>
      "El documento no incluye este dato: en ARCA III (Orona PDCM), página 64, " \
      "el significado funcional de los puntos de BYPASS P32-P35, P35-P35B y " \
      "P35B-P36 es DATA_NOT_AVAILABLE en este diagrama.",
    "holdout_v4_fain_ekm1000_jumper_abierto_seguridad" =>
      "En la placa EKM 1000 (EM66, RECOBA/FAIN), página 79, con el Jumper 1 en " \
      "posición abierta queda FALTA FASE OK: la detección de falta de fase " \
      "está activa. Esta es la condición segura y normal para la operación del " \
      "ascensor.",
    "holdout_v4_arca3_bypass_j26_seguridad" =>
      "Con el puente en posición J26, el ARCA III entra en modo de revisión con " \
      "las cerraduras exteriores puenteadas; a diferencia de J24 (que puentea " \
      "las seguridades de cabina) o J25 (que puentea las cerraduras de " \
      "cabina), este puente J26 puentea específicamente las cerraduras " \
      "exteriores.",
    "holdout_v4_carlos_silva_tpr70_b7_seguridad" =>
      "En la placa HIDRA-TPR70 (CARLOS SILVA), página 11, el conector B7 " \
      "conecta en el mismo hilo en serie a LIMITADOR, FINALES, STOP FOSO y " \
      "POLEA TENSORA. El orden exacto de la cadena y cuál terminal es " \
      "inicio/retorno REQUIRES_FIELD_VERIFICATION -- el diagrama no imprime " \
      "esa secuencia con texto.",
    "holdout_v4_thyssen_cmc4_cn26_seguridad" =>
      "En la placa CMC4 (THYSSEN, página 97), el conector CN26 agrupa STOP " \
      "FOSO, POLEA TENSORA y AMORTIGUADOR en los pines A3/A4/A5. La " \
      "asignación pin-a-pin exacta REQUIRES_FIELD_VERIFICATION -- no es " \
      "legible con certeza en este diagrama.",
    "holdout_v4_thyssen_cmc4_cn25_cn37_comparativa" =>
      "En la placa CMC4 (THYSSEN, página 97), CN25 conecta CERROJOS FRONTALES " \
      "mientras que CN37 conecta CERROJOS TRASEROS, ambos con los mismos " \
      "pines C4, C3 y GND."
  }.freeze

  setup do
    @rubric = JSON.parse(File.read(FIXTURE_PATH))
  end

  test "fixture has the 14-question stratified distribution from Fase 5" do
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

  test "real max_score sums to 136 (max_score/passing_score fields are documental only)" do
    total = @rubric.fetch("cases").sum do |c|
      c.fetch("required").size * 2 + c.fetch("optional").size + (@rubric.fetch("citation_required") ? 2 : 0)
    end

    assert_equal 136, total
    assert_equal 136, @rubric.fetch("max_score"), "documental max_score drifted from the real evaluator sum"
    assert_equal 109, @rubric.fetch("passing_score"), "passing_score must be ceil(80% of the real sum)"
    assert_equal 109, (total * 0.8).ceil
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

      assert_equal true, definition.fetch("source_page_required"),
        "#{definition.fetch('id')}: security-stratum case must carry source_page_required=true"

      definition.fetch("penalized").each do |pattern|
        assert_equal "critical", pattern.fetch("severity"),
          "#{definition.fetch('id')}: penalized pattern #{pattern['label']} must carry " \
          "severity=critical, not safety_critical (evaluator does not weigh " \
          "safety_critical as a pattern severity -- N4, benchmark_rubric_evaluator.rb:8-13)"
      end
    end
  end

  test "no case reuses a v1/v2/v3 question verbatim" do
    reused_fixtures = [
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v1.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v2.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v3.json")
    ]
    previous_questions = reused_fixtures.flat_map do |path|
      JSON.parse(File.read(path)).fetch("cases").map { |c| c.fetch("question") }
    end

    v4_questions = @rubric.fetch("cases").map { |c| c.fetch("question") }
    assert_empty v4_questions & previous_questions
  end

  test "at least 4 cases target the FAIN/RECOBA and THYSSEN duplicate clusters naming a page (N10 coverage)" do
    cluster_pages = [ 46, 76, 77, 78, 79, 92, 97 ]
    cluster_cases = @rubric.fetch("cases").select do |c|
      Array(c["source_pages"]).intersect?(cluster_pages) && c.fetch("question").match?(/p[áa]gina\s+\d+/i)
    end

    assert_operator cluster_cases.size, :>=, 4,
      "expected >=4 cases naming a page inside the FAIN/RECOBA/THYSSEN duplicate clusters, got #{cluster_cases.pluck('id')}"
  end

  test "exactly one case is multi-board (ambigua stratum, N11 coverage)" do
    ambigua_cases = @rubric.fetch("cases").select { |c| c.fetch("stratum") == "ambigua" }
    assert_equal 1, ambigua_cases.size
    assert_operator Array(ambigua_cases.first["source_pages"]).size, :>=, 2,
      "the ambigua case should span more than one source page (multi-board)"
  end

  test "each case verifies offline as not an ambiguous_hardware_query? (rule f)" do
    @rubric.fetch("cases").each do |definition|
      assert_not Rag::DeterministicIntent.ambiguous_hardware_query?(definition.fetch("question")),
        "#{definition.fetch('id')}: question must not route to the disambiguation menu"
    end
  end

  test "each penalized pattern does not fire on a known-correct answer, and required/citation/page checks pass" do
    @rubric.fetch("cases").each do |definition|
      id = definition.fetch("id")
      answer = KNOWN_CORRECT_ANSWERS.fetch(id)
      cited_page = Array(definition["source_pages"]).first

      payload = {
        "run_id" => "qa-holdout-v4",
        "results" => [
          {
            "id" => id,
            "answer" => answer,
            "citations" => [ { "title" => "SEGURIDADES 1.1-1 — p. #{cited_page || '?'}" } ]
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

      assert_equal true, result.fetch("source_page_required"),
        "#{id}: this fixture sets source_page_required=true (deliberately) on every case"
      assert result.fetch("source_page_cited"),
        "#{id}: known-correct answer's citation page (#{cited_page}) should land in source_pages " \
        "(#{definition['source_pages']}) -- #{result['source_pages']}"

      assert result.fetch("passed"), "#{id}: known-correct answer should pass the case outright"
    end
  end
end
