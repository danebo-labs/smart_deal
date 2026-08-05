# frozen_string_literal: true

require "optparse"

# Read-only daily pilot export. Real LLM calls and costs come from BedrockQuery;
# zero-cost cache reuse comes from the optional structured log extract.
#
# Usage:
#   bin/rails runner script/pilot_metrics_export.rb
#   PILOT_USAGE_LOG=tmp/pilot.log bin/rails runner script/pilot_metrics_export.rb 2026-07-22
#
# Human-readable summary instead of raw JSON (presentation only, same
# PilotMetricsReport contract underneath):
#   bin/rails runner script/pilot_metrics_export.rb --pretty
#   PILOT_EXPORT_FORMAT=human bin/rails runner script/pilot_metrics_export.rb 2026-07-22
#
# Print both the human summary and the raw JSON:
#   bin/rails runner script/pilot_metrics_export.rb --both
#
# Opt-in only: include real question text (text/RAG queries only) in
# evidence_quality.recent_questions. Off by default — interaction_completed/
# interactions/repeat_usage always hash the question (question_sha256) and
# this flag does not change that; it surfaces the already-logged [RAG_QUALITY]
# text instead. See docs/METRICS.md for the privacy boundary this crosses.
#   bin/rails runner script/pilot_metrics_export.rb --with-questions
#   PILOT_EXPORT_INCLUDE_QUESTIONS=true bin/rails runner script/pilot_metrics_export.rb
#
# Extract logs before rotation:
#   kamal app logs --lines 20000 | grep -E 'PILOT_USAGE|RAG_QUALITY' > tmp/pilot.log

abort("Run with: bin/rails runner script/pilot_metrics_export.rb") unless defined?(Rails)

options = {
  format: ENV["PILOT_EXPORT_FORMAT"].presence || "raw",
  include_raw_questions: ENV["PILOT_EXPORT_INCLUDE_QUESTIONS"] == "true",
  user_ids: ENV["PILOT_USER_IDS"].to_s.split(",").map(&:strip).compact_blank,
  usage_log: ENV["PILOT_USAGE_LOG"]
}
OptionParser.new do |parser|
  parser.on("--from DATE") { |value| options[:from] = Date.parse(value) }
  parser.on("--to DATE") { |value| options[:to] = Date.parse(value) }
  parser.on("--user-ids IDS") { |value| options[:user_ids] = value.split(",").map(&:strip).compact_blank }
  parser.on("--account SLUG") { |value| options[:account] = value }
  parser.on("--roles ROLES") { |value| options[:roles] = value.split(",").map(&:strip).compact_blank }
  parser.on("--stdin-logs") { options[:stdin_logs] = true }
  parser.on("--format FORMAT", %w[raw human both]) { |value| options[:format] = value }
  parser.on("--with-questions") { options[:include_raw_questions] = true }
  parser.on("--pretty", "--human") { options[:format] = "human" }
  parser.on("--both") { options[:format] = "both" }
end.parse!(ARGV)

date = ARGV.shift.presence
abort("Unexpected arguments: #{ARGV.join(' ')}") if ARGV.any?
date = Date.parse(date) if date

if options[:from] && options[:to] && options[:from] > options[:to]
  abort("--from must be on or before --to")
end

user_ids = options[:user_ids]
if options[:account]
  account_user_ids = Account.find_by!(slug: options[:account]).users.pluck(:id).map(&:to_s)
  user_ids = user_ids.any? ? user_ids & account_user_ids : account_user_ids
end

report = PilotMetricsReport.new(
  date: date || (options[:from] || options[:to] ? nil : Time.zone.today),
  from: options[:from],
  to: options[:to],
  usage_log_path: options[:stdin_logs] ? $stdin : options[:usage_log],
  user_ids: user_ids,
  roles: options[:roles],
  include_raw_questions: options[:include_raw_questions]
).as_json

case options[:format]
when "human"
  puts PilotMetricsHumanFormatter.new(report)
when "both"
  puts PilotMetricsHumanFormatter.new(report)
  puts JSON.generate(report)
else
  puts JSON.generate(report)
end
