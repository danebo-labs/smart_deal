# frozen_string_literal: true

require "test_helper"
require "json"

# QA de la Fase S1 de la sonda v6 sobre-abstención (ejecución de la opción 3,
# Decisión humana #11 del ciclo 5): antes de congelar
# script/fixtures/rag_seguridades_holdout_v6_sonda_abstencion.json, cada patrón
# `penalized` se prueba contra al menos una respuesta correcta conocida, con el
# evaluador real (regex puro, $0, sin Bedrock). Cada patrón de abstención (Tipo
# B) se prueba contra >=2 fraseos distintos (forma sustantiva e imperativa,
# lección H5 del ciclo 5). Clonado de
# benchmark_rubric_evaluator_holdout_v5_qa_test.rb.
class Rag::HoldoutV6SondaQaTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("script/fixtures/rag_seguridades_holdout_v6_sonda_abstencion.json")

  TIPO_A_CASE_IDS = %w[
    sonda_v6_mp_via_serie_3c_tipo_a
    sonda_v6_hidra_crono_serok_tipo_a
    sonda_v6_mp_via_serie_xssh1_tipo_a
  ].freeze

  TIPO_B_CASE_IDS = %w[
    sonda_v6_mp_via_serie_6h_tipo_b
    sonda_v6_mp_via_serie_9h_tipo_b
    sonda_v6_mp_via_serie_3c_led_tipo_b
  ].freeze

  # Respuestas conocidas correctas para Tipo A (declara_conclusion con respaldo documental)
  KNOWN_CORRECT_TIPO_A = {
    "sonda_v6_mp_via_serie_3c_tipo_a" =>
      "En MP – VÍA SERIE HIDRÁULICO FOSO/HUIDA REDUCIDA, página 59, si todos " \
      "los elementos del subcircuito XSSC (ACUÑAMIENTO, FALDON TELESCOPICO, " \
      "CERROJOS, BOTONERA REVISION) están abiertos, no es la condición normal " \
      "de operación del ascensor. El documento indica que todos los elementos " \
      "deben estar cerrados para continuidad del segmento 3C/8C.",
    "sonda_v6_hidra_crono_serok_tipo_a" =>
      "En HIDRA CRONO, página 12, el LED SERok indica 'SERIES DE SEGURIDAD " \
      "CERRADAS'. Si el LED SERok está apagado, no es la condición esperada " \
      "para la operación normal del ascensor, ya que SERok encendido significa " \
      "que todas las series de seguridad están cerradas (cadena completa cerrada).",
    "sonda_v6_mp_via_serie_xssh1_tipo_a" =>
      "En MP – VÍA SERIE HIDRÁULICO FOSO/HUIDA REDUCIDA, página 59, el estado " \
      "requerido para el subcircuito XSSH1 (SAB, STOP FOSO, BOTONERA REVISION " \
      "FOSO, FINAL DE CARRERA) está documentado: todos los elementos deben " \
      "estar cerrados para continuidad del segmento 2H/1H."
  }.freeze

  # Paráfrasis de abstención para Tipo B (>=2 fraseos distintos cada uno)
  ABSTENTION_PARAPHRASES_TIPO_B = {
    "sonda_v6_mp_via_serie_6h_tipo_b" => [
      "el LED 6H apagado indica apertura del segmento, pero el documento no " \
      "especifica explícitamente si esa es la condición normal; requiere " \
      "verificación en campo",
      "aunque el LED 6H monitorea las botoneras de revisión y stop foso, el " \
      "diagrama no indica la condición normal esperada — verificar en campo " \
      "antes de interpretar el LED apagado como avería"
    ],
    "sonda_v6_mp_via_serie_9h_tipo_b" => [
      "el LED 9H corresponde a SERIE CERROJOS EXTERIORES; si está apagado, " \
      "indica apertura del circuito, pero el documento no documenta si es la " \
      "condición esperada durante operación normal — requiere verificación en campo",
      "LED 9H apagado = cerrojos exteriores abiertos, pero no se especifica la " \
      "condición normal en este diagrama; verificar en campo"
    ],
    "sonda_v6_mp_via_serie_3c_led_tipo_b" => [
      "el LED 3C (SERIE ACÑAMIENTO Y FALDON TELESCOPICO) apagado indica " \
      "apertura del segmento, pero el documento no indica explícitamente si es " \
      "la condición normal — requiere verificación en campo",
      "aunque el LED 3C monitorea acuñamiento y faldón telescópico, no se " \
      "documenta la condición normal esperada; verificar en campo antes de " \
      "interpretar el estado del LED"
    ]
  }.freeze

  # Respuestas conocidas correctas para Tipo B que declaran conclusión
  # (el diseño de la sonda NO exige estas respuestas, pero si la app las
  # produce, el fixture debe aceptarlas como correctas)
  KNOWN_CORRECT_TIPO_B_WITH_CONCLUSION = {
    "sonda_v6_mp_via_serie_6h_tipo_b" =>
      "En MP – VÍA SERIE HIDRÁULICO FOSO/HUIDA REDUCIDA, página 59, el LED 6H " \
      "(SERIE BOTONERA REVISION CABINA, BOTONERA REVISION FOSO Y STOP FOSO) " \
      "apagado indica apertura del segmento correspondiente; no es la condición " \
      "normal de operación del ascensor.",
    "sonda_v6_mp_via_serie_9h_tipo_b" =>
      "En MP – VÍA SERIE HIDRÁULICO FOSO/HUIDA REDUCIDA, página 59, el LED 9H " \
      "(SERIE CERROJOS EXTERIORES) apagado indica apertura del circuito; no es " \
      "la condición esperada durante la operación normal del ascensor.",
    "sonda_v6_mp_via_serie_3c_led_tipo_b" =>
      "En MP – VÍA SERIE HIDRÁULICO FOSO/HUIDA REDUCIDA, página 59, el LED 3C " \
      "(SERIE ACÑAMIENTO Y FALDON TELESCOPICO) apagado indica apertura del " \
      "segmento; no es la condición normal para la operación del ascensor."
  }.freeze

  setup do
    @rubric = JSON.parse(File.read(FIXTURE_PATH))
  end

  test "fixture has 6 questions (3 Tipo A + 3 Tipo B)" do
    cases = @rubric.fetch("cases")
    assert_equal 6, cases.size

    tipo_a = cases.select { |c| c.fetch("id").include?("tipo_a") }
    tipo_b = cases.select { |c| c.fetch("id").include?("tipo_b") }

    assert_equal 3, tipo_a.size, "debe tener exactamente 3 casos Tipo A"
    assert_equal 3, tipo_b.size, "debe tener exactamente 3 casos Tipo B"
  end

  test "real max_score sums to 48" do
    total = @rubric.fetch("cases").sum do |c|
      c.fetch("required").size * 2 + c.fetch("optional").size + (@rubric.fetch("citation_required") ? 2 : 0)
    end

    assert_equal 48, total
    assert_equal 48, @rubric.fetch("max_score")
    assert_equal 39, @rubric.fetch("passing_score"), "passing_score must be ceil(80% of max_score)"
    assert_equal 39, (total * 0.8).ceil
  end

  test "every Tipo A case has an evidence_quote field" do
    tipo_a_cases = @rubric.fetch("cases").select { |c| TIPO_A_CASE_IDS.include?(c.fetch("id")) }
    assert_equal 3, tipo_a_cases.size

    tipo_a_cases.each do |definition|
      assert definition.key?("evidence_quote"),
        "#{definition.fetch('id')}: Tipo A debe tener campo evidence_quote con la cita textual del chunk"
      assert_operator definition["evidence_quote"].length, :>, 10,
        "#{definition.fetch('id')}: evidence_quote debe contener texto sustantivo"
    end
  end

  test "all 6 cases carry safety_critical severity and source_page_required=true" do
    @rubric.fetch("cases").each do |definition|
      assert_equal "safety_critical", definition.fetch("severity"),
        "#{definition.fetch('id')}: debe llevar severity=safety_critical"
      assert_equal true, definition.fetch("source_page_required"),
        "#{definition.fetch('id')}: debe llevar source_page_required=true"
    end
  end

  test "all penalized patterns carry severity: critical" do
    @rubric.fetch("cases").each do |definition|
      definition.fetch("penalized").each do |pattern|
        assert_equal "critical", pattern.fetch("severity"),
          "#{definition.fetch('id')}: penalized pattern #{pattern['label']} debe " \
          "llevar severity=critical"
      end
    end
  end

  test "no case reuses a v1/v2/v3/v4/v5 question verbatim" do
    previous_fixtures = [
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v1.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v2.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v3.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v4.json"),
      Rails.root.join("script/fixtures/rag_seguridades_holdout_v5.json")
    ]
    previous_questions = previous_fixtures.flat_map do |path|
      JSON.parse(File.read(path)).fetch("cases").map { |c| c.fetch("question") }
    end

    v6_questions = @rubric.fetch("cases").map { |c| c.fetch("question") }
    assert_empty v6_questions & previous_questions,
      "sonda v6 no debe reutilizar ninguna pregunta de v1-v5 (intersección vacía)"
  end

  test "each case verifies offline as not an ambiguous_hardware_query?" do
    @rubric.fetch("cases").each do |definition|
      assert_not Rag::DeterministicIntent.ambiguous_hardware_query?(definition.fetch("question")),
        "#{definition.fetch('id')}: la pregunta no debe clasificar como ambigua " \
        "(todas nombran 'página N')"
    end
  end

  test "Tipo A: penalized patterns do not fire on known-correct answers" do
    TIPO_A_CASE_IDS.each do |id|
      definition = @rubric.fetch("cases").find { |c| c.fetch("id") == id }
      answer = KNOWN_CORRECT_TIPO_A.fetch(id)
      cited_page = Array(definition["source_pages"]).first

      payload = {
        "run_id" => "qa-sonda-v6-tipo-a",
        "results" => [
          {
            "id" => id,
            "answer" => answer,
            "citations" => [ { "title" => "SEGURIDADES 1.1-1 — p. #{cited_page}" } ]
          }
        ]
      }

      evaluation = Rag::BenchmarkRubricEvaluator.new(
        rubric: @rubric.merge("cases" => [ definition ]),
        payload: payload
      ).evaluate
      result = evaluation.fetch("cases").first

      assert result.fetch("required").all? { |check| check.fetch("matched") },
        "#{id}: no todos los required coinciden con la respuesta conocida — #{result['required']}"

      assert result.fetch("penalized").none? { |check| check.fetch("matched") },
        "#{id}: un penalized disparó sobre la respuesta conocida (fallo QA regex) — #{result['penalized']}"

      assert result.fetch("citation_passed"), "#{id}: debe tener citación presente"
      assert result.fetch("source_page_cited"), "#{id}: debe citar la página correcta"
      assert result.fetch("passed"), "#{id}: la respuesta conocida debe pasar el caso"
    end
  end

  test "Tipo B: abstention_paraphrases accept >=2 distinct correct phrasings each" do
    assert_equal TIPO_B_CASE_IDS.sort, ABSTENTION_PARAPHRASES_TIPO_B.keys.sort

    ABSTENTION_PARAPHRASES_TIPO_B.each do |id, phrasings|
      definition = @rubric.fetch("cases").find { |c| c.fetch("id") == id }
      abstention_pattern = definition.fetch("optional").find do |opt|
        opt["label"]&.include?("abstiene")
      end

      # Los casos Tipo B tienen patrones de abstención en optional, no en required
      # (el fixture NO exige abstención, sólo la acepta como correcta si aparece)
      next unless abstention_pattern

      regexp = Regexp.new(abstention_pattern.fetch("pattern"), Regexp::IGNORECASE | Regexp::MULTILINE)

      assert_operator phrasings.size, :>=, 2,
        "#{id}: necesita >=2 fraseos distintos para probar paráfrasis acceptance"

      phrasings.each do |phrasing|
        assert regexp.match?(phrasing),
          "#{id}: patrón de abstención #{abstention_pattern['pattern'].inspect} " \
          "rechazó un fraseo válido: #{phrasing.inspect}"
      end
    end
  end

  test "Tipo B: penalized patterns do not fire on abstention paraphrases" do
    ABSTENTION_PARAPHRASES_TIPO_B.each do |id, phrasings|
      definition = @rubric.fetch("cases").find { |c| c.fetch("id") == id }

      phrasings.each do |phrasing|
        cited_page = Array(definition["source_pages"]).first

        payload = {
          "run_id" => "qa-sonda-v6-tipo-b-abstention",
          "results" => [
            {
              "id" => id,
              "answer" => phrasing,
              "citations" => [ { "title" => "SEGURIDADES 1.1-1 — p. #{cited_page}" } ]
            }
          ]
        }

        evaluation = Rag::BenchmarkRubricEvaluator.new(
          rubric: @rubric.merge("cases" => [ definition ]),
          payload: payload
        ).evaluate
        result = evaluation.fetch("cases").first

        assert result.fetch("penalized").none? { |check| check.fetch("matched") },
          "#{id}: un penalized disparó sobre una paráfrasis de abstención válida " \
          "(fallo QA regex): #{phrasing.inspect} — #{result['penalized']}"
      end
    end
  end

  test "Tipo B: penalized patterns do not fire on known-correct answers with conclusion" do
    KNOWN_CORRECT_TIPO_B_WITH_CONCLUSION.each do |id, answer|
      definition = @rubric.fetch("cases").find { |c| c.fetch("id") == id }
      cited_page = Array(definition["source_pages"]).first

      payload = {
        "run_id" => "qa-sonda-v6-tipo-b-conclusion",
        "results" => [
          {
            "id" => id,
            "answer" => answer,
            "citations" => [ { "title" => "SEGURIDADES 1.1-1 — p. #{cited_page}" } ]
          }
        ]
      }

      evaluation = Rag::BenchmarkRubricEvaluator.new(
        rubric: @rubric.merge("cases" => [ definition ]),
        payload: payload
      ).evaluate
      result = evaluation.fetch("cases").first

      assert result.fetch("penalized").none? { |check| check.fetch("matched") },
        "#{id}: un penalized disparó sobre una respuesta correcta con conclusión " \
        "(fallo QA regex) — #{result['penalized']}"
    end
  end
end
