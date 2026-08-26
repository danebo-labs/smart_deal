# frozen_string_literal: true

require "test_helper"
require "json"
require "tempfile"

ENV["PILOT_BATTERY_LIBRARY_ONLY"] = "1"
require Rails.root.join("script/pilot_release_precision_battery")
ENV.delete("PILOT_BATTERY_LIBRARY_ONLY")

# Test del arnés de PilotReleasePrecisionBattery (Paso 6): resolución de rutas
# de fixtures por env var, parseo de configuración, y la lógica pura (matching
# de identidad por SHA-256, veredicto del gate, forma de result_row) — todo
# sin llamar a Bedrock ni tocar la base de datos. La corrida real (fases
# a-d contra producción) es la Fase 4 del plan, fuera de este test.
class PilotReleasePrecisionBatteryTest < ActiveSupport::TestCase
  def with_fixture_files(questions:, rubric:)
    Tempfile.create(%w[questions .json]) do |qf|
      qf.write(JSON.generate(questions))
      qf.flush

      Tempfile.create(%w[rubric .json]) do |rf|
        rf.write(JSON.generate(rubric))
        rf.flush

        yield(qf.path, rf.path)
      end
    end
  end

  test "PILOT_BATTERY_QUESTIONS and PILOT_BATTERY_RUBRIC override the default fixture paths" do
    questions = [ { "id" => "q1", "brand" => "KONE", "expected_sha256" => "a" * 64, "generation_subset" => false } ]
    rubric = { "version" => "test", "citation_required" => true, "cases" => [] }

    with_fixture_files(questions: questions, rubric: rubric) do |q_path, r_path|
      battery = PilotReleasePrecisionBattery.new(
        env: { "PILOT_BATTERY_QUESTIONS" => q_path, "PILOT_BATTERY_RUBRIC" => r_path }
      )

      assert_equal questions, battery.instance_variable_get(:@questions)
      assert_equal rubric, battery.instance_variable_get(:@rubric)
    end
  end

  test "uses the default fixture paths when no env override is set" do
    default_questions_path = Rails.root.join("script/fixtures/pilot_release_precision_battery_questions.json")
    default_rubric_path = Rails.root.join("script/fixtures/pilot_release_precision_battery_rubric.json")

    if File.exist?(default_questions_path) && File.exist?(default_rubric_path)
      battery = PilotReleasePrecisionBattery.new(env: {})
      assert_equal 60, battery.instance_variable_get(:@questions).size
      assert_kind_of Hash, battery.instance_variable_get(:@rubric)
    else
      skip "Default fixtures not present in test environment"
    end
  end

  test "DRY_RUN=1 sets @dry_run true; unset/absent leaves it false" do
    questions = []
    rubric = { "version" => "test", "citation_required" => true, "cases" => [] }

    with_fixture_files(questions: questions, rubric: rubric) do |q_path, r_path|
      env = { "PILOT_BATTERY_QUESTIONS" => q_path, "PILOT_BATTERY_RUBRIC" => r_path }

      dry = PilotReleasePrecisionBattery.new(env: env.merge("DRY_RUN" => "1"))
      assert dry.instance_variable_get(:@dry_run)

      full = PilotReleasePrecisionBattery.new(env: env)
      assert_not full.instance_variable_get(:@dry_run)
    end
  end

  test "numeric config env vars parse with documented defaults" do
    questions = []
    rubric = { "version" => "test", "citation_required" => true, "cases" => [] }

    with_fixture_files(questions: questions, rubric: rubric) do |q_path, r_path|
      env = { "PILOT_BATTERY_QUESTIONS" => q_path, "PILOT_BATTERY_RUBRIC" => r_path }

      defaults = PilotReleasePrecisionBattery.new(env: env)
      assert_equal 3, defaults.instance_variable_get(:@account_id)
      assert_equal 5, defaults.instance_variable_get(:@top_k)
      assert_in_delta 2.5, defaults.instance_variable_get(:@budget_ceiling_usd), 0.0001

      overridden = PilotReleasePrecisionBattery.new(env: env.merge(
        "PILOT_BATTERY_ACCOUNT_ID" => "7",
        "PILOT_BATTERY_TOP_K" => "8",
        "PILOT_BATTERY_BUDGET_CEILING" => "1.25"
      ))
      assert_equal 7, overridden.instance_variable_get(:@account_id)
      assert_equal 8, overridden.instance_variable_get(:@top_k)
      assert_in_delta 1.25, overridden.instance_variable_get(:@budget_ceiling_usd), 0.0001
    end
  end

  test "chunk_matches_sha? compares metadata doc_sha256 against the expected SHA-256, string and symbol keys both" do
    questions = []
    rubric = { "version" => "test", "citation_required" => true, "cases" => [] }

    with_fixture_files(questions: questions, rubric: rubric) do |q_path, r_path|
      battery = PilotReleasePrecisionBattery.new(
        env: { "PILOT_BATTERY_QUESTIONS" => q_path, "PILOT_BATTERY_RUBRIC" => r_path }
      )
      expected = "a" * 64
      other = "b" * 64

      chunk_string_key = { metadata: { "doc_sha256" => expected } }
      chunk_symbol_key = { metadata: { doc_sha256: expected } }
      chunk_mismatch = { metadata: { "doc_sha256" => other } }
      chunk_missing = { metadata: {} }

      assert battery.send(:chunk_matches_sha?, chunk_string_key, expected)
      assert battery.send(:chunk_matches_sha?, chunk_symbol_key, expected)
      assert_not battery.send(:chunk_matches_sha?, chunk_mismatch, expected)
      assert_not battery.send(:chunk_matches_sha?, chunk_missing, expected)
    end
  end

  test "result_row omits nil-valued keys (generation_mode/error) but always keeps id/answer/citations/budget_aborted" do
    questions = []
    rubric = { "version" => "test", "citation_required" => true, "cases" => [] }

    with_fixture_files(questions: questions, rubric: rubric) do |q_path, r_path|
      battery = PilotReleasePrecisionBattery.new(
        env: { "PILOT_BATTERY_QUESTIONS" => q_path, "PILOT_BATTERY_RUBRIC" => r_path }
      )

      aborted_row = battery.send(:result_row, id: "q1", budget_aborted: true)
      assert_equal(
        { "id" => "q1", "answer" => "", "citations" => [], "budget_aborted" => true },
        aborted_row
      )

      full_row = battery.send(
        :result_row, id: "q2", budget_aborted: false, answer: "respuesta",
        citations: [ { "title" => "x" } ], generation_mode: "bedrock_retrieve_and_generate"
      )
      assert_equal "q2", full_row["id"]
      assert_equal "respuesta", full_row["answer"]
      assert_equal "bedrock_retrieve_and_generate", full_row["generation_mode"]
      assert_not full_row.key?("error")
    end
  end

  test "gate_verdict computes retrieval and generation pass rates against the plan's fixed thresholds (85%/80%)" do
    questions = []
    rubric = { "version" => "test", "citation_required" => true, "cases" => [] }

    with_fixture_files(questions: questions, rubric: rubric) do |q_path, r_path|
      battery = PilotReleasePrecisionBattery.new(
        env: { "PILOT_BATTERY_QUESTIONS" => q_path, "PILOT_BATTERY_RUBRIC" => r_path }
      )

      # 52/60 retrieval hits (86.67% >= 85%), 16/20 generation cases passed (80% >= 80%).
      retrieval = Array.new(52) { { "hit_in_top_k" => true } } + Array.new(8) { { "hit_in_top_k" => false } }
      evaluation = { "summary" => { "cases" => 20, "passed" => 16 } }

      verdict = battery.send(:gate_verdict, retrieval, evaluation)

      assert_equal 52, verdict["retrieval_hits"]
      assert_equal 60, verdict["retrieval_total"]
      assert verdict["retrieval_pass"]
      assert verdict["generation_pass"]
      assert verdict["overall_pass"]

      # Un solo hit menos de retrieval (51/60 = 85.0%, todavía pasa) vs. justo por debajo.
      barely_failing = Array.new(50) { { "hit_in_top_k" => true } } + Array.new(10) { { "hit_in_top_k" => false } }
      failing_verdict = battery.send(:gate_verdict, barely_failing, evaluation)
      assert_not failing_verdict["retrieval_pass"], "50/60 = 83.3% no debe pasar el umbral de 85%"
      assert_not failing_verdict["overall_pass"], "overall_pass debe ser false si falla cualquiera de los dos umbrales"
    end
  end

  test "raises before any Bedrock call if QUERY_ROUTING_ENABLED=true (safety guard)" do
    questions = []
    rubric = { "version" => "test", "citation_required" => true, "cases" => [] }

    with_fixture_files(questions: questions, rubric: rubric) do |q_path, r_path|
      battery = PilotReleasePrecisionBattery.new(
        env: { "PILOT_BATTERY_QUESTIONS" => q_path, "PILOT_BATTERY_RUBRIC" => r_path }
      )

      original = ENV["QUERY_ROUTING_ENABLED"]
      ENV["QUERY_ROUTING_ENABLED"] = "true"
      begin
        assert_raises(RuntimeError) { battery.run! }
      ensure
        ENV["QUERY_ROUTING_ENABLED"] = original
      end
    end
  end
end
