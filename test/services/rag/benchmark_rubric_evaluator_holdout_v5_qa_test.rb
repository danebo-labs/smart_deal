# frozen_string_literal: true

require "test_helper"
require "json"

# QA de la Fase 4 del ciclo 5 (docs/rag/plan_ciclo5_resolucion_decision9_2026-08-04.md):
# antes de congelar script/fixtures/rag_seguridades_holdout_v5.json, cada
# patrón `penalized` se prueba contra al menos una respuesta correcta
# conocida, con el evaluador real (regex puro, $0, sin Bedrock). Clonado de
# benchmark_rubric_evaluator_holdout_v4_qa_test.rb, con una verificación
# nueva propia del v5: el falso negativo H5 del gate v4 (un `required` de
# abstención con objeto literal único no aceptaba paráfrasis correctas) --
# aquí se prueban los 2 patrones de abstención de "orden de cadena no
# documentado" contra >=2 fraseos distintos cada uno (forma sustantiva e
# imperativa, con el objeto alternado).
class Rag::BenchmarkRubricEvaluatorHoldoutV5QaTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("script/fixtures/rag_seguridades_holdout_v5.json")

  SECURITY_CASE_IDS = %w[
    holdout_v5_recoba_ksa18_orden_cadena_seguridad
    holdout_v5_mp_via_serie_led2h_seguridad
    holdout_v5_zeus_hats_j11_etiqueta_seguridad
    holdout_v5_recoba_ekm64_orden_terminales_seguridad
  ].freeze

  KNOWN_CORRECT_ANSWERS = {
    "holdout_v5_recoba_ksa18_h15_h6" =>
      "En RECOBA KSA 18 HIDRÁULICO, página 71, el LED H15 corresponde a SERIE " \
      "DE CERROJOS CERRADA y el LED H6 corresponde a SERIE PUERTAS DE PISO " \
      "CERRADAS.",
    "holdout_v5_recoba_ekm64_h67_h64" =>
      "En RECOBA EKM64 ELÉCTRICO, página 73, el LED H67 corresponde a SERIE " \
      "SEGURIDADES PRINCIPALES y el LED H64 corresponde a SERIE CERROJOS " \
      "CABINA - EXTERIORES.",
    "holdout_v5_mp_via_serie_6h_9h" =>
      "En MP – VÍA SERIE HIDRÁULICO FOSO/HUIDA REDUCIDA, página 59, el LED 6H " \
      "corresponde a SERIE BOTONERA REVISION CABINA, BOTONERA REVISION FOSO Y " \
      "STOP FOSO, y el LED 9H corresponde a SERIE CERROJOS EXTERIORES.",
    "holdout_v5_kone_divisor_epb" =>
      "En la página divisoria de KONE, página 51, el modelo listado junto a " \
      "MONOESPACE es EPB.",
    "holdout_v5_zeus_hats_stopfoso_j10" =>
      "En el controlador ZEUS/HATS, página 48, STOP FOSO está conectado al " \
      "conector J10, no a J9.",
    "holdout_v5_recoba_ksa18_bornes_grupo" =>
      "En RECOBA KSA 18 HIDRÁULICO, página 71, el grupo de bornes 14, 15, 21, " \
      "22, 9, 10 conecta a ACUÑAMI./AFLOJACAB., CERROJOS CABINA y BOTONERA " \
      "REVISIÓN.",
    "holdout_v5_zeus_hats_j9_solo" =>
      "En el controlador ZEUS/HATS, página 48, el conector J9 conecta " \
      "CERROJOS EMBARQUE 1, CERROJOS EMBARQUE 2, BOTO. REVISION, ACUÑAMIENTO " \
      "y AFLOJACABLES; estos componentes no están en el conector J10.",
    "holdout_v5_edel_codigo_37_ambigua" =>
      "En EDEL, el terminal 37 en la placa EDEL-542 (página 24) está " \
      "conectado a BOTO. REVISION, mientras que en la placa EDEL-K3 (página " \
      "26) el LED 37 corresponde a SERIE PUERTAS HUECO; no es el mismo " \
      "significado en ambas placas.",
    "holdout_v5_em3000_pin_pos_sin_respaldo" =>
      "En EM3000 (ELECMEGON), página 29, el pin POS del conector CN de " \
      "OBSTÁCULO no está documentado en este diagrama: su función es " \
      "DATA_NOT_AVAILABLE.",
    "holdout_v5_recoba_ksa18_orden_cadena_seguridad" =>
      "En RECOBA KSA 18 HIDRÁULICO, página 71, el grupo de bornes 14, 15, 21, " \
      "22, 9, 10 conecta a ACUÑAMI./AFLOJACAB., CERROJOS CABINA y BOTONERA " \
      "REVISIÓN, pero el orden exacto de esa cadena no está documentado en el " \
      "diagrama — requiere verificación en campo antes de desconectar " \
      "cualquier cable.",
    "holdout_v5_mp_via_serie_led2h_seguridad" =>
      "En MP – VÍA SERIE HIDRÁULICO FOSO/HUIDA REDUCIDA, página 59, si el LED " \
      "2H está apagado, esto indica apertura del segmento SAB hueco y final " \
      "de carrera; no es la condición normal para la operación del ascensor.",
    "holdout_v5_zeus_hats_j11_etiqueta_seguridad" =>
      "En el controlador ZEUS/HATS, página 48, el conector J11 conecta " \
      "TRAMPILLA MANTENIMIENTO y LIMITADOR; la etiqueta impresa para J11 es " \
      "parcialmente legible y requiere verificación en campo antes de " \
      "intervenir sobre ese conector.",
    "holdout_v5_recoba_ekm64_orden_terminales_seguridad" =>
      "En RECOBA EKM64 ELÉCTRICO, página 73, los terminales DC, LS, LB y LSO " \
      "del bloque C1 conectan en el mismo tramo a ACUÑAMIENTO, pero el orden " \
      "exacto de esos cuatro terminales dentro de la cadena no está " \
      "documentado en el diagrama — requiere verificación en campo antes de " \
      "desconectar un cable.",
    "holdout_v5_recoba_ksa18_presostato_termistor_comparativa" =>
      "En RECOBA KSA 18 HIDRÁULICO, página 71, PRESOSTATO y TERMISTOR MOTOR " \
      "(NTC 3D-5) comparten el grupo de bornes 32 y 33: PRESOSTATO aparece en " \
      "la mitad superior del grupo y TERMISTOR MOTOR aparece en la mitad " \
      "inferior."
  }.freeze

  # H5 (falso negativo del gate v4): cada required de abstención de "orden de
  # cadena no documentado" debe aceptar >=2 fraseos distintos -- forma
  # sustantiva ("requiere verificación en campo") e imperativa ("verificar
  # ... en campo"), sin depender de un objeto literal único.
  ABSTENTION_PARAPHRASES = {
    "holdout_v5_recoba_ksa18_orden_cadena_seguridad" => [
      "el orden exacto de esa cadena no está documentado en el diagrama — " \
      "requiere verificación en campo antes de desconectar cualquier cable",
      "el diagrama no indica la secuencia textual de esos elementos; hay que " \
      "verificar el orden en campo antes de desconectar el cable"
    ],
    "holdout_v5_recoba_ekm64_orden_terminales_seguridad" => [
      "el orden exacto de esos cuatro terminales dentro de la cadena no está " \
      "documentado en el diagrama — requiere verificación en campo antes de " \
      "desconectar un cable",
      "no se especifica esa secuencia en el diagrama; verificar el orden en " \
      "campo antes de tocar el cableado"
    ]
  }.freeze

  setup do
    @rubric = JSON.parse(File.read(FIXTURE_PATH))
  end

  test "fixture has the 14-question stratified distribution from Fase 4" do
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

  test "real max_score sums to 129 (max_score/passing_score fields are documental only)" do
    total = @rubric.fetch("cases").sum do |c|
      c.fetch("required").size * 2 + c.fetch("optional").size + (@rubric.fetch("citation_required") ? 2 : 0)
    end

    assert_equal 129, total
    assert_equal 129, @rubric.fetch("max_score"), "documental max_score drifted from the real evaluator sum"
    assert_equal 104, @rubric.fetch("passing_score"), "passing_score must be ceil(80% of the real sum)"
    assert_equal 104, (total * 0.8).ceil
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

  test "no case reuses a v1/v2/v3/v4 question verbatim" do
    reused_fixtures = [
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v1.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v2.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v3.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v4.json")
    ]
    previous_questions = reused_fixtures.flat_map do |path|
      JSON.parse(File.read(path)).fetch("cases").map { |c| c.fetch("question") }
    end

    v5_questions = @rubric.fetch("cases").map { |c| c.fetch("question") }
    assert_empty v5_questions & previous_questions
  end

  test "exactly one case is multi-board (ambigua stratum, N11-style coverage)" do
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
        "run_id" => "qa-holdout-v5",
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

  test "H5 fix: abstention required patterns accept >=2 distinct correct phrasings each" do
    assert_equal SECURITY_CASE_IDS.select { |id| id.include?("orden") }.sort, ABSTENTION_PARAPHRASES.keys.sort

    ABSTENTION_PARAPHRASES.each do |id, phrasings|
      definition = @rubric.fetch("cases").find { |c| c.fetch("id") == id }
      abstention_pattern = definition.fetch("required").find { |r| r["label"].include?("no está documentado") }
      assert abstention_pattern, "#{id}: expected an abstention required pattern"

      regexp = Regexp.new(abstention_pattern.fetch("pattern"), Regexp::IGNORECASE | Regexp::MULTILINE)

      assert_operator phrasings.size, :>=, 2, "#{id}: needs >=2 distinct phrasings to prove paraphrase acceptance"
      phrasings.each do |phrasing|
        assert regexp.match?(phrasing),
          "#{id}: abstention pattern #{abstention_pattern['pattern'].inspect} rejected a valid paraphrase: #{phrasing.inspect}"
      end
    end
  end
end
