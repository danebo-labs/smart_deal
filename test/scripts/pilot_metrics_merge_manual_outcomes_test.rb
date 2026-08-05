# frozen_string_literal: true

require "test_helper"
require "tempfile"

class PilotMetricsMergeManualOutcomesTest < ActiveSupport::TestCase
  test "merges only matching manual outcomes into by_correlation" do
    report = Tempfile.new([ "pilot-report", ".json" ])
    report.write(JSON.generate(
      interactions: {
        by_correlation: [
          {
            correlation_id: "query:matched",
            correct_answer: nil,
            resolved: nil,
            technician_helpfulness: nil
          },
          {
            correlation_id: "query:unmatched",
            correct_answer: nil,
            resolved: nil,
            technician_helpfulness: nil
          }
        ]
      },
      commercial_outcomes: { status: "REQUIRES_MANUAL_SURVEY" }
    ))
    report.flush
    outcomes = Tempfile.new([ "manual-outcomes", ".csv" ])
    outcomes.write(<<~CSV)
      correlation_id,correct_answer,resolved,helpfulness
      query:matched,yes,no,helpful
      query:absent,no,no,not_helpful
    CSV
    outcomes.flush
    previous_argv = ARGV.dup
    ARGV.replace([ report.path, outcomes.path ])

    stdout, _stderr = capture_io do
      load Rails.root.join("script/pilot_metrics_merge_manual_outcomes.rb")
    end
    merged = JSON.parse(stdout)
    matched, unmatched = merged.dig("interactions", "by_correlation")

    assert_equal "yes", matched.fetch("correct_answer")
    assert_equal "no", matched.fetch("resolved")
    assert_equal "helpful", matched.fetch("technician_helpfulness")
    assert_nil unmatched.fetch("correct_answer")
    assert_nil unmatched.fetch("resolved")
    assert_nil unmatched.fetch("technician_helpfulness")
    assert_equal "REQUIRES_MANUAL_SURVEY", merged.dig("commercial_outcomes", "status")
  ensure
    ARGV.replace(previous_argv) if previous_argv
    report&.close!
    outcomes&.close!
  end

  test "requires the exact manual outcome headers" do
    report = Tempfile.new([ "pilot-report", ".json" ])
    report.write(JSON.generate(interactions: { by_correlation: [] }))
    report.flush
    outcomes = Tempfile.new([ "manual-outcomes", ".csv" ])
    outcomes.write("correlation_id,correct_answer,resolved\n")
    outcomes.flush
    previous_argv = ARGV.dup
    ARGV.replace([ report.path, outcomes.path ])

    error = assert_raises(SystemExit) do
      capture_io { load Rails.root.join("script/pilot_metrics_merge_manual_outcomes.rb") }
    end

    assert_equal 1, error.status
  ensure
    ARGV.replace(previous_argv) if previous_argv
    report&.close!
    outcomes&.close!
  end
end
