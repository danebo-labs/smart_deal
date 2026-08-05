# frozen_string_literal: true

require "csv"

abort(
  "Run with: bin/rails runner script/pilot_metrics_merge_manual_outcomes.rb REPORT_JSON OUTCOMES_CSV"
) unless defined?(Rails)

report_path, outcomes_path = ARGV.values_at(0, 1)
abort("REPORT_JSON and OUTCOMES_CSV are required") unless report_path && outcomes_path

outcomes = CSV.read(outcomes_path, headers: true)
required_headers = %w[correlation_id correct_answer resolved helpfulness]
missing_headers = required_headers - outcomes.headers
abort("manual outcomes CSV missing headers: #{missing_headers.join(',')}") if missing_headers.any?

by_correlation = outcomes.index_by { |outcome| outcome["correlation_id"] }
report = JSON.parse(File.read(report_path))

Array(report.dig("interactions", "by_correlation")).each do |interaction|
  outcome = by_correlation[interaction["correlation_id"]]
  next unless outcome

  interaction["correct_answer"] = outcome["correct_answer"]
  interaction["resolved"] = outcome["resolved"]
  interaction["technician_helpfulness"] = outcome["helpfulness"]
end

puts JSON.generate(report)
