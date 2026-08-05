# frozen_string_literal: true

abort("Run with: bin/rails runner script/pilot_metrics_render.rb REPORT_JSON") unless defined?(Rails)

report_path = ARGV.fetch(0)
report = JSON.parse(File.read(report_path)).deep_symbolize_keys
puts PilotMetricsHumanFormatter.new(report)
