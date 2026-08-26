# frozen_string_literal: true

require "test_helper"
require "json"

# QA offline de los dos fixtures del Paso 6 (docs/PLAN_LIBERACION_PILOTO_2026-08-25.md):
# script/fixtures/pilot_release_precision_battery_questions.json (60,
# estratificadas 10/marca) y .../pilot_release_precision_battery_rubric.json
# (subconjunto de 20 con rúbrica completa). Corre offline, $0, sin Bedrock —
# valida forma antes de que la corrida real (Fase 4) gaste crédito.
class PilotReleasePrecisionBatteryFixturesTest < ActiveSupport::TestCase
  QUESTIONS_PATH = Rails.root.join("script/fixtures/pilot_release_precision_battery_questions.json")
  RUBRIC_PATH = Rails.root.join("script/fixtures/pilot_release_precision_battery_rubric.json")

  EXPECTED_PER_BRAND_TOTAL = 10
  EXPECTED_GENERATION_SUBSET_BY_BRAND = {
    "KONE" => 4, "TKE" => 4, "BLT" => 5, "OTIS" => 3, "FUJI YIDA" => 2, "MITSUBISHI" => 2
  }.freeze

  # Assets que el Paso 2 dejó `failed` en cuenta 3 — nunca deben ser la fuente
  # de una pregunta (garantizarían un fallo de retrieval que no prueba el fix).
  KNOWN_FAILED_BASENAMES = [ "otis_2000.pdf", "V3F18 MX05 MX06 MX10.pdf" ].freeze

  setup do
    @questions = JSON.parse(File.read(QUESTIONS_PATH))
    @rubric = JSON.parse(File.read(RUBRIC_PATH))
  end

  test "exactly 60 questions, 10 per brand, across exactly the 6 in-scope brands" do
    assert_equal 60, @questions.size
    by_brand = @questions.group_by { |q| q.fetch("brand") }
    assert_equal EXPECTED_GENERATION_SUBSET_BY_BRAND.keys.sort, by_brand.keys.sort
    by_brand.each do |brand, questions|
      assert_equal EXPECTED_PER_BRAND_TOTAL, questions.size, "#{brand}: esperaba 10 preguntas"
    end
  end

  test "exactly 20 questions marked generation_subset, matching the weighted per-brand distribution" do
    generation_subset = @questions.select { |q| q["generation_subset"] }
    assert_equal 20, generation_subset.size

    by_brand = generation_subset.group_by { |q| q.fetch("brand") }.transform_values(&:size)
    assert_equal EXPECTED_GENERATION_SUBSET_BY_BRAND, by_brand
  end

  test "all 60 question ids are unique" do
    ids = @questions.map { |q| q.fetch("id") }
    assert_equal ids.size, ids.uniq.size
  end

  test "every question has a well-formed 64-hex-char expected_sha256" do
    @questions.each do |q|
      sha = q.fetch("expected_sha256")
      assert_match(/\A[0-9a-f]{64}\z/, sha, "#{q.fetch('id')}: expected_sha256 mal formado")
    end
  end

  test "no question is sourced from a BulkUploadAsset already known to be failed" do
    @questions.each do |q|
      assert_not_includes KNOWN_FAILED_BASENAMES, q.fetch("expected_basename"),
        "#{q.fetch('id')}: usa #{q.fetch('expected_basename')}, un asset conocido como fallido (Paso 2) — " \
        "garantizaría un miss de retrieval que no prueba nada"
    end
  end

  test "the rubric fixture has exactly one case per generation_subset question, ids bijective" do
    generation_subset_ids = @questions.select { |q| q["generation_subset"] }.map { |q| q.fetch("id") }
    rubric_ids = @rubric.fetch("cases").map { |c| c.fetch("id") }

    assert_equal 20, rubric_ids.size
    assert_equal rubric_ids.size, rubric_ids.uniq.size, "la rúbrica tiene ids de caso duplicados"
    assert_equal generation_subset_ids.sort, rubric_ids.sort,
      "los ids de generation_subset en questions.json y los ids de cases en rubric.json deben coincidir exactamente"
  end

  test "no generation_subset question routes to the ambiguous_hardware_query? disambiguation menu" do
    @questions.select { |q| q["generation_subset"] }.each do |q|
      assert_not Rag::DeterministicIntent.ambiguous_hardware_query?(q.fetch("question")),
        "#{q.fetch('id')}: la pregunta clasifica como ambigua — Rag::AmbiguousModelResponder " \
        "devolvería un menú de desambiguación en vez de una respuesta sustantiva, reprobando " \
        "casi cualquier `required` de la rúbrica sin que sea un problema real del sistema"
    end
  end

  test "every rubric case's required/optional/penalized patterns compile as valid regexes" do
    @rubric.fetch("cases").each do |definition|
      %w[required optional penalized].each do |bucket|
        Array(definition[bucket]).each do |check|
          assert_nothing_raised do
            Regexp.new(check.fetch("pattern"), Regexp::IGNORECASE | Regexp::MULTILINE)
          end
        end
      end
    end
  end

  test "every rubric case declares source_page_required: false explicitly" do
    @rubric.fetch("cases").each do |definition|
      assert_equal false, definition.fetch("source_page_required"),
        "#{definition.fetch('id')}: debe declarar source_page_required: false explícitamente"
    end
  end

  test "every rubric case has at least one required check (never an empty rubric)" do
    @rubric.fetch("cases").each do |definition|
      assert definition.fetch("required").present?,
        "#{definition.fetch('id')}: un caso sin required no verifica nada"
    end
  end

  test "the BLT mandatory PLC questions from Paso 2 are present verbatim and unmodified" do
    blt_plc_input = @questions.find { |q| q.fetch("id") == "blt_01" }
    blt_plc_output = @questions.find { |q| q.fetch("id") == "blt_02" }
    blt_conectores_qs = @questions.find { |q| q.fetch("id") == "blt_03" }

    assert_equal "¿Cuáles son las entradas del PLC del escalador BLT y qué señales Omron documenta?",
      blt_plc_input.fetch("question")
    assert_equal "¿Qué salidas documenta el PLC BLT-ES output para bobinas y contactores?",
      blt_plc_output.fetch("question")
    assert_equal "¿Cómo se identifican los bornes y pines de los conectores QS?",
      blt_conectores_qs.fetch("question")

    [ blt_plc_input, blt_plc_output, blt_conectores_qs ].each do |q|
      assert q.fetch("generation_subset"), "#{q.fetch('id')}: las 3 preguntas de PLC BLT deben ir en el subconjunto de generación"
    end
  end
end
