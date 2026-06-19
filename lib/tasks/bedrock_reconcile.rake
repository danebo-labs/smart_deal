# frozen_string_literal: true

# Reconcile app-recorded Bedrock spend against the AWS bill.
# AWS Cost Explorer/CUR buckets usage by UTC calendar day.
#
# `:reconcile`      — fast estimate from BedrockQuery rows (no AWS calls).
#                     Bucketed by UTC. Note: estimated rows undercount input
#                     tokens and are timestamped at async job-run time, so the
#                     per-day split is approximate. Use `:reconcile_logs` for truth.
# `:reconcile_logs` — authoritative cost from Bedrock Model Invocation Logs in S3
#                     (exact tokens + cache + real invocation timestamp). Matches
#                     the AWS bill. Requires invocation logging to be enabled.
#
#   bin/rails 'bedrock:reconcile[2026-06-18,0.34]'
#   bin/rails 'bedrock:reconcile_logs[2026-06-18,0.34]'
namespace :bedrock do
  desc "Estimate Bedrock cost for a UTC day from BedrockQuery rows (date[,aws_usd])"
  task :reconcile, %i[date aws_usd] => :environment do |_t, args|
    date = args[:date] ? Date.parse(args[:date]) : Time.now.utc.to_date - 1
    rep  = BedrockQuery.aws_reconciliation(date)

    puts "== Bedrock ESTIMATE (BedrockQuery rows) — #{date} (UTC day) =="
    printf("%-50s %5s %10s %10s %12s\n", "model_id", "n", "inCost", "outCost", "cost")
    rep[:rows].each do |r|
      printf("%-50s %5d %10.5f %10.5f %12.5f  (est %d/%d)\n",
             r[:model_id], r[:count], r[:input_cost], r[:output_cost], r[:cost],
             r[:estimated], r[:count])
    end
    printf("%-50s %5s %10s %10s %12.5f\n", "TOTAL", "", "", "", rep[:total_cost])
    puts "estimated row share: #{(rep[:estimated_share] * 100).round(1)}%"
    compare(rep[:total_cost], args[:aws_usd])
  end

  desc "Persist authoritative Bedrock cost for a UTC day into bedrock_daily_costs (date)"
  task :reconcile_persist, %i[date] => :environment do |_t, args|
    date = args[:date] ? Date.parse(args[:date]) : Time.now.utc.to_date - 1
    rep  = ReconcileBedrockCostJob.perform_now(date.to_s)
    puts "Persisted #{rep[:rows].size} model row(s) for #{date} (UTC) — total $#{rep[:total_cost]}"
    cmp = BedrockDailyCost.truth_vs_estimate(date)
    puts "truth $#{cmp[:truth]}  estimate $#{cmp[:estimate]}  drift #{cmp[:est_drift_pct]}%"
  end

  desc "Authoritative Bedrock cost for a UTC day from S3 invocation logs (date[,aws_usd])"
  task :reconcile_logs, %i[date aws_usd] => :environment do |_t, args|
    date = args[:date] ? Date.parse(args[:date]) : Time.now.utc.to_date - 1
    rep  = BedrockInvocationLogReconciler.new.day(date)

    puts "== Bedrock TRUTH (S3 invocation logs) — #{date} (UTC day) =="
    printf("%-50s %5s %9s %9s %9s %9s %12s\n", "model_id", "n", "in", "out", "cacheR", "cacheW", "cost")
    rep[:rows].each do |r|
      printf("%-50s %5d %9d %9d %9d %9d %12.5f\n",
             r[:model_id], r[:count], r[:input_tokens], r[:output_tokens],
             r[:cache_read_tokens], r[:cache_write_tokens], r[:cost])
    end
    printf("%-50s %5s %9s %9s %9s %9s %12.5f\n", "TOTAL", "", "", "", "", "", rep[:total_cost])
    compare(rep[:total_cost], args[:aws_usd])
  end
end

def compare(app_cost, aws_usd)
  return unless aws_usd

  aws  = aws_usd.to_f
  diff = app_cost - aws
  pct  = aws.zero? ? 0.0 : (diff / aws * 100)
  puts "AWS bill: $#{aws.round(4)}  computed: $#{app_cost.round(4)}  " \
       "delta: #{diff >= 0 ? '+' : ''}#{diff.round(4)} (#{pct.round(1)}%)"
end
