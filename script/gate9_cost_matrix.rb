# frozen_string_literal: true

# Gate 9R cost matrix — reproducible pricing scenarios with ZERO external calls.
#
# Usage:
#   bin/rails runner script/gate9_cost_matrix.rb
#
# Sources: script/fixtures/gate9_run4_cohort.json (token telemetry snapshot) +
# ContractualLimits (finite technical limits). Money is derived via the
# versioned pricing table in Gate9CostMatrix — never stored as data.

abort("Run with: bin/rails runner script/gate9_cost_matrix.rb") unless defined?(Rails)

report = Gate9CostMatrix.new.report

fmt = ->(value) { format("$%.4f", value) }

puts "Gate 9R historical/technical matrix — NOT current package COGS"
puts "Canonical current model: docs/SAAS_COST_MODEL_2026-06-12.md"
puts "Pricing version #{report[:pricing_version]}"
puts "=" * 72

manual = report[:manual]
puts "\nMANUAL — run4 cohort (n=#{manual[:n_pages_cohort]} kept pages) scaled to #{manual[:scale_target_pages]}pp"
puts "  Batch-repriced first attempts; truncated-page retries billed direct."
puts "\n  expected (observed cache pattern):"
puts "    parse ×200                  #{fmt.call(manual[:expected][:parse_x200_cache])}"
puts "    of which retries direct     #{fmt.call(manual[:expected][:retries_direct_x200])}"
puts "    of which wasted truncated   #{fmt.call(manual[:expected][:wasted_first_attempts_x200])}"
puts "    page filter (Haiku)         #{fmt.call(manual[:expected][:page_filter_x200])}"
puts "    embeddings (Titan v2)       #{fmt.call(manual[:expected][:embeddings_x200])}"
puts "    L2 total                    #{format('$%.2f', manual[:expected][:l2_total_cache])}"
puts "\n  conservative (no cache):"
puts "    parse ×200                  #{fmt.call(manual[:conservative][:parse_x200_no_cache])}"
puts "    L2 total                    #{format('$%.2f', manual[:conservative][:l2_total_no_cache])}"
puts "\n  O3′ cap 8k (simulated — truncations eliminated):"
puts "    parse ×200 cache            #{fmt.call(manual[:o3_cap8k][:parse_x200_cache])}"
puts "    parse ×200 no-cache         #{fmt.call(manual[:o3_cap8k][:parse_x200_no_cache])}"
puts "    avoidable cost (cache)      #{fmt.call(manual[:o3_cap8k][:avoidable_cost_cache])}"
puts "    avoidable cost (no-cache)   #{fmt.call(manual[:o3_cap8k][:avoidable_cost_no_cache])}"
puts "    L2 total cache / no-cache   #{format('$%.2f / $%.2f', manual[:o3_cap8k][:l2_total_cache], manual[:o3_cap8k][:l2_total_no_cache])}"
puts "\n  splits (cache scenario):"
puts "    Sonnet / Opus               #{fmt.call(manual[:splits][:sonnet_x200_cache])} / #{fmt.call(manual[:splits][:opus_x200_cache])}"
puts "    Batch firsts / direct retry #{fmt.call(manual[:splits][:batch_first_attempts_cache])} / #{fmt.call(manual[:splits][:direct_retries_cache])}"
puts "    no-cache penalty (delta)    #{fmt.call(manual[:splits][:cache_penalty_no_cache_delta])}"

queries = report[:queries]
puts "\nQUERIES — HISTORICAL certification cohort (n=#{queries[:n_queries]} queries, #{queries[:n_model_calls]} model calls; basis: #{queries[:basis]})"
puts "    expected / 1000             #{fmt.call(queries[:expected_per_1000])}"
puts "    conservative (100% gen)     #{fmt.call(queries[:conservative_per_1000])}"
recon = queries[:ledger_reconciliation]
puts "    V1 ledger reconciliation    app #{fmt.call(recon[:app_ledger_cost])} vs CloudWatch #{fmt.call(recon[:cloudwatch_cost])} " \
     "(app underestimates #{recon[:app_underestimation_pct]}%)"
puts "    rule: #{recon[:rule]}"

photos = report[:photos]
puts "\nPHOTOS — HISTORICAL provisional sample (n=#{photos[:n]}; #{photos[:note]})"
puts "    expected / 200              #{fmt.call(photos[:expected_per_200])}"
puts "    conservative / 200          #{fmt.call(photos[:conservative_per_200])}"

cmax = report[:contractual_max]
puts "\nCONTRACTUAL MAX — #{cmax[:basis]}"
puts "    queries / 1000              #{format('$%.2f', cmax[:queries_per_1000])}"
puts "    photos / 200                #{format('$%.2f', cmax[:photos_per_200])}"
puts "    manual 200pp                #{format('$%.2f', cmax[:manual_200pp])}"
puts "\nNOTE: p50/p95 describe observed usage; the contractual ceiling above is"
puts "a finite worst-case from technical limits, not a price."
puts "Current COGS: $9.54 expected / $13.27 conservative recurring;"
puts "manual onboarding: $5.32 one-time."
