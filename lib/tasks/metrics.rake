# frozen_string_literal: true

namespace :metrics do
  desc <<~DESC
    Rebuild CostMetric rollups from BedrockQuery rows for a date range.
    Idempotent — uses upsert_all; never deletes BedrockQuery rows.

    Usage:
      bin/rails metrics:rebuild_cost_rollups                         # all dates with data
      bin/rails "metrics:rebuild_cost_rollups[2026-01-01,2026-06-08]"  # explicit range
  DESC
  task :rebuild_cost_rollups, [:start_date, :end_date] => :environment do |_t, args|
    first = BedrockQuery.minimum(:created_at)&.to_date
    last  = BedrockQuery.maximum(:created_at)&.to_date

    if first.nil?
      puts "No BedrockQuery rows found — nothing to rebuild."
      next
    end

    start_date = args[:start_date].present? ? Date.parse(args[:start_date]) : first
    end_date   = args[:end_date].present?   ? Date.parse(args[:end_date])   : last

    puts "Rebuilding CostMetric rollups for #{start_date}..#{end_date}"

    (start_date..end_date).each do |date|
      SimpleMetricsService.update_database_metrics_only(date: date)
      print "."
    end

    puts "\nDone. #{(start_date..end_date).count} day(s) rebuilt."
  end
end
