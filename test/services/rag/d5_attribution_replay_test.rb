# frozen_string_literal: true

require "test_helper"

class Rag::D5AttributionReplayTest < ActiveSupport::TestCase
  SOURCE_DIR = Rails.root.join("tmp/d5_abstention_contract")
  OUTPUT_DIR = Rails.root.join("tmp/replay_attribution")
  THYSSEN_EXPECTED_SHA256 = "9adc01b4e1603f29c36670e484ef92a272ba0461c054b308f7442c993f8805ce"

  setup do
    skip "D5 paid artifacts are not available on this machine" unless SOURCE_DIR.directory?

    capture_io { load Rails.root.join("script/replay_d5_attribution_contract.rb") }
    @report = JSON.parse(OUTPUT_DIR.join("replay_report.json").read)
  end

  test "replay preserves all baselines and changes only the two contract cases" do
    assert_equal 32, @report.fetch("fidelity_matches")
    assert_equal 32, @report.fetch("fidelity_total")
    assert_equal 32, @report.fetch("flag_off_matches")
    assert_equal %w[thyssen_e_led edel_k3_leds], @report.fetch("changed_ids")
    assert_equal 30, @report.fetch("unchanged_results")
    assert_equal 19, @report.fetch("structured_turns")
    assert_empty @report.fetch("new_citation_failures")
    assert_equal 0, @report.fetch("regressions")
    assert @report.fetch("source_integrity").all? { |item| item.fetch("matched") }
  end

  test "Thyssen replay removes only the foreign-family segment" do
    payload = payload("d5_rag_seguridades_rubric_run1.json")
    result = payload.fetch("results").find { |item| item["id"] == "thyssen_e_led" }
    row = report_row("thyssen_e_led")

    %w[NE\ 300 LB\ II DFC DW misma\ lógica].each do |forbidden|
      assert_not_includes result.fetch("answer"), forbidden.tr("\\", "")
    end
    %w[L9 L8 L7].each { |required| assert_includes result.fetch("answer"), required }
    assert_includes result.fetch("answer"), "no especifica"
    assert_includes result.fetch("answer"), "El documento no incluye este dato"
    assert_includes result.fetch("answer"), "[1]"
    assert_not_includes result.fetch("answer"), "[2]"
    assert_equal THYSSEN_EXPECTED_SHA256, Digest::SHA256.hexdigest(result.fetch("answer"))
    assert_equal 1, row.fetch("dropped_segments").size
    assert row.fetch("dropped_segments").first.start_with?(". **Nota:**")

    evaluation = payload.fetch("evaluation").fetch("cases")
      .find { |item| item["id"] == "thyssen_e_led" }
    assert_equal true, evaluation.fetch("passed")
    assert_equal 5, evaluation.fetch("score")
    assert_equal true, evaluation.dig("required", 0, "matched")
    assert_equal true, evaluation.dig("optional", 0, "matched")
    assert_equal false, evaluation.dig("penalized", 0, "matched")
  end

  test "Edel replay runs the full local route with one normalized citation" do
    payload = payload("d5_rag_seguridades_pilot_10q_v2_run1.json")
    result = payload.fetch("results").find { |item| item["id"] == "edel_k3_leds" }
    row = report_row("edel_k3_leds")

    assert_includes result.fetch("answer"), "37"
    assert_includes result.fetch("answer"), "PUERTAS HUECO"
    assert_includes result.fetch("answer"), "39"
    assert_includes result.fetch("answer"), "PUERTAS CABINA"
    assert_includes result.fetch("answer"), "41"
    assert_includes result.fetch("answer"), "CERROJOS CABINA Y EXTERIORES"
    assert_equal 1, result.fetch("citations").size
    assert_equal "answered", row.fetch("outcome_status")
    assert_nil row["outcome_reason"]
    assert_equal 1, row.fetch("retrieve_invocations")
    assert_equal 1, row.fetch("generation_chunks")
    assert_equal 0, row.fetch("expansion_count")

    evaluation = payload.fetch("evaluation").fetch("cases")
      .find { |item| item["id"] == "edel_k3_leds" }
    assert_equal true, evaluation.fetch("passed")
    assert evaluation.fetch("required").all? { |check| check.fetch("matched") }
    assert_equal true, evaluation.fetch("citation_passed")
    assert_equal false, evaluation.dig("penalized", 0, "matched")
  end

  private

  def payload(filename)
    JSON.parse(OUTPUT_DIR.join(filename).read)
  end

  def report_row(id)
    @report.fetch("rows").find { |item| item["id"] == id }
  end
end
