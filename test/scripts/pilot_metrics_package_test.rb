# frozen_string_literal: true

require "test_helper"
require "csv"
require "fileutils"
require "tmpdir"

class PilotMetricsPackageTest < ActiveSupport::TestCase
  test "merges optional outcomes and writes every human artifact in one run" do
    tmpdir = Dir.mktmpdir("pilot-metrics-package")
    report_path = File.join(tmpdir, "report.json")
    report = JSON.parse(
      Rails.root.join("test/fixtures/files/pilot_metrics_11_interactions.json").read
    )
    interaction = report.dig("interactions", "by_correlation")[1]
    interaction["input_tokens"] = 100
    interaction["output_tokens"] = 20
    interaction["audit"] = {
      "question" => "¿Pregunta completa?",
      "answer" => "Respuesta completa y auditable.",
      "citations" => [
        { "number" => 1, "title" => "CARLOS SILVA — p. 11", "filename" => "manual.pdf", "page" => 11 }
      ],
      "chunks" => [
        {
          "document" => "CARLOS SILVA", "page" => 11, "section_identity" => "TPR70",
          "chunk_sha256" => "chunk-sha", "text" => "Texto completo del chunk.", "truncated" => false
        }
      ]
    }
    File.write(report_path, JSON.generate(report))
    outcomes_path = File.join(tmpdir, "outcomes.csv")
    File.write(outcomes_path, <<~CSV)
      correlation_id,correct_answer,resolved,helpfulness
      query:20c886b3-234f-425b-8908-92f1487bd3af,yes,yes,helpful
      query:aa0fce1b-7849-4a47-b09a-377d6c07419f,no,no,not_helpful
    CSV
    previous_argv = ARGV.dup
    ARGV.replace([ report_path, tmpdir, outcomes_path ])

    capture_io { load Rails.root.join("script/pilot_metrics_package.rb") }

    %w[report.json report.txt valor.json dossier.html interactions.csv].each do |name|
      assert_path_exists File.join(tmpdir, name)
    end
    merged = JSON.parse(File.read(report_path))
    assert_equal "yes", merged.dig("interactions", "by_correlation", 1, "correct_answer")
    value = JSON.parse(File.read(File.join(tmpdir, "valor.json")))
    assert_equal 0.5, value.dig("precision_and_safety", "verified_correct_rate")
    assert_equal "available", value.dig("precision_and_safety", "verification_status")

    dossier = File.read(File.join(tmpdir, "dossier.html"))
    assert_includes dossier, "¿Pregunta completa?"
    assert_includes dossier, "Respuesta completa y auditable."
    assert_includes dossier, "CARLOS SILVA — p. 11"
    assert_includes dossier, "Texto completo del chunk."
    assert_includes dossier, "query:20c886b3-234f-425b-8908-92f1487bd3af"
    assert_no_match(%r{https?://}, dossier)

    rows = CSV.read(File.join(tmpdir, "interactions.csv"), headers: true)
    assert_equal 11, rows.size
    assert_equal "¿Pregunta completa?", rows.find { |row| row["correlation_id"] == interaction["correlation_id"] }["question"]

    bad_outcomes = File.join(tmpdir, "bad-outcomes.csv")
    File.write(bad_outcomes, "correlation_id,correct_answer,resolved\n")
    error = assert_raises(SystemExit) do
      capture_io do
        PilotMetricsPackage.new(
          report_path: report_path,
          output_dir: tmpdir,
          outcomes_path: bad_outcomes
        ).call
      end
    end
    assert_equal 1, error.status
  ensure
    ARGV.replace(previous_argv) if previous_argv
    FileUtils.remove_entry(tmpdir) if tmpdir && File.exist?(tmpdir)
  end
end
