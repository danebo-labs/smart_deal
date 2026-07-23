# frozen_string_literal: true

# Read-only daily pilot export. Real LLM calls and costs come from BedrockQuery;
# zero-cost cache reuse comes from the optional structured log extract.
#
# Usage:
#   bin/rails runner script/pilot_metrics_export.rb
#   PILOT_USAGE_LOG=tmp/pilot.log bin/rails runner script/pilot_metrics_export.rb 2026-07-22
#
# Extract logs before rotation:
#   kamal app logs --lines 20000 | grep -E 'PILOT_USAGE|RAG_QUALITY' > tmp/pilot.log

abort("Run with: bin/rails runner script/pilot_metrics_export.rb") unless defined?(Rails)

date = ARGV.first.presence ? Date.parse(ARGV.first) : Time.zone.today
user_ids = ENV["PILOT_USER_IDS"].to_s.split(",").map(&:strip).compact_blank
report = PilotMetricsReport.new(
  date: date,
  usage_log_path: ENV["PILOT_USAGE_LOG"],
  user_ids: user_ids
)
puts JSON.generate(report.as_json)
