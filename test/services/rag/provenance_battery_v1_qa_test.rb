# frozen_string_literal: true

require "test_helper"
require "json"

# QA estructural de la Fase 4 del ciclo 5
# (docs/rag/plan_ciclo5_resolucion_decision9_2026-08-04.md) para
# script/fixtures/rag_seguridades_provenance_battery_v1.json. A diferencia del
# holdout, esta batería no usa una rúbrica de texto: sus checks son
# determinísticos sobre campos estructurados (canonical_name de una cita /
# ausencia de un patrón en el cuerpo crudo) que sólo pueden evaluarse contra
# una respuesta real de Bedrock -- por eso este test es puramente offline
# (integridad del fixture, sin llamadas a Bedrock/Anthropic, $0), y el runner
# real que sí llama a Bedrock se abre UNA vez en la Fase 6.
#
# Verdad-terreno de cada expected_section_identity: docs/rag/gate_a_medicion_topologia.md
# §5.2 (Apéndice E de las 18 divisoras) -- incluye los 2 verbatims con
# discrepancia documentada del extractor T1 (CARLOS SILVA, HATS_-_ASOCIADOS),
# que no aplican al campo section_identity de esta batería (T1 es un motor de
# topología no relacionado con el ingestion pipeline de RAG que escribe los
# sidecars), pero se preservan como el verbatim de referencia de la Fase 8.
class Rag::ProvenanceBatteryV1QaTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("script/fixtures/rag_seguridades_provenance_battery_v1.json")

  # docs/rag/gate_a_medicion_topologia.md §5.2 -- las 18 divisoras, marca extraída.
  DIVISOR_GROUND_TRUTH = {
    2 => "ALJO",
    8 => "CARLOS SILVA",
    15 => "CTA",
    23 => "EDEL",
    27 => "ELECMEGON",
    35 => "ENIER",
    37 => "EXCELSIOR",
    41 => "FAIN",
    47 => "HATS_-_ASOCIADOS",
    49 => "INELCA",
    51 => "KONE",
    54 => "MP",
    60 => "ORONA",
    66 => "OTIS",
    70 => "RECOBA",
    80 => "SCHINDLER",
    87 => "SISTEL",
    92 => "THYSSEN"
  }.freeze

  setup do
    @fixture = JSON.parse(File.read(FIXTURE_PATH))
  end

  test "fixture is frozen with 18 cases: 10 neighbor-expansion + 8 absence-of-N8" do
    cases = @fixture.fetch("cases")
    assert_equal 18, cases.size
    assert_equal(
      { "neighbor_expansion_divisor_identity" => 10, "absence_of_n8_contamination" => 8 },
      cases.map { |c| c.fetch("check_category") }.tally
    )
  end

  test "no duplicate ids and no question reused across cases" do
    cases = @fixture.fetch("cases")
    ids = cases.map { |c| c.fetch("id") }
    assert_equal ids.uniq.size, ids.size

    questions = cases.map { |c| c.fetch("question") }
    assert_equal questions.uniq.size, questions.size
  end

  test "all 18 cases carry severity: safety_critical (both fixes are P0 traceability blockers)" do
    @fixture.fetch("cases").each do |c|
      assert_equal "safety_critical", c.fetch("severity"), "#{c.fetch('id')}: expected safety_critical"
    end
  end

  test "every neighbor_expansion_divisor_identity case targets a real divisor page with the right expected_section_identity (Gate A §5.2)" do
    divisor_cases = @fixture.fetch("cases").select { |c| c.fetch("check_category") == "neighbor_expansion_divisor_identity" }
    assert_equal 10, divisor_cases.size

    divisor_cases.each do |c|
      page = c.fetch("divisor_page")
      assert DIVISOR_GROUND_TRUTH.key?(page), "#{c.fetch('id')}: page #{page} is not one of the 18 documented divisors"
      assert_equal DIVISOR_GROUND_TRUTH.fetch(page), c.fetch("expected_section_identity"),
        "#{c.fetch('id')}: expected_section_identity drifted from Gate A Apéndice E for divisor page #{page}"
      assert_equal "citation_canonical_name_equals_section_identity", c.dig("check", "type")
      assert_equal c.fetch("expected_section_identity"), c.dig("check", "expected_section_identity")
      assert c.fetch("expected_neighbor_pages").present?, "#{c.fetch('id')}: needs at least one neighbor page"
      assert c.fetch("expected_neighbor_pages").all? { |p| p > page }, "#{c.fetch('id')}: neighbor pages must come after the divisor"
    end

    # 10 distinct brands -- diversidad deliberada de familias de layout, no repetir marca.
    assert_equal 10, divisor_cases.map { |c| c.fetch("expected_section_identity") }.uniq.size
  end

  test "every absence_of_n8_contamination case targets a non-ALJO page (except the deliberate ALJO control) with forbidden_patterns that compile" do
    absence_cases = @fixture.fetch("cases").select { |c| c.fetch("check_category") == "absence_of_n8_contamination" }
    assert_equal 8, absence_cases.size

    non_control_cases = absence_cases.reject { |c| c.fetch("id").include?("aljo_anchor") }
    assert_equal 7, non_control_cases.size
    non_control_cases.each do |c|
      assert_not_equal "ALJO", c.fetch("expected_section_identity"),
        "#{c.fetch('id')}: absence-of-N8 cases (besides the ALJO control) must target a NON-ALJO page"
    end

    absence_cases.each do |c|
      assert_equal "absence_of_forbidden_patterns_in_retrieved_content", c.dig("check", "type")
      patterns = c.dig("check", "forbidden_patterns")
      assert patterns.present?, "#{c.fetch('id')}: needs at least one forbidden_pattern"
      patterns.each do |pattern|
        assert_nothing_raised { Regexp.new(pattern) }
      end
    end
  end

  test "each question names the target/divisor page explicitly (page-pin routing, no ambiguous_hardware_query? risk)" do
    @fixture.fetch("cases").each do |c|
      assert c.fetch("question").match?(/p[áa]gina\s+\d+/i), "#{c.fetch('id')}: question must name a page"
      assert_not Rag::DeterministicIntent.ambiguous_hardware_query?(c.fetch("question")),
        "#{c.fetch('id')}: question must not route to the disambiguation menu"
    end
  end
end
