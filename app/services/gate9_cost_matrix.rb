# frozen_string_literal: true

# Gate 9R cost matrix (plan B3-script — blocking gate).
#
# Rebuilds, WITHOUT any external call, three pricing scenarios from telemetry
# snapshots plus finite technical limits:
#
#   expected        — observed distribution (run4 cohort / certification / photo
#                     samples), each figure with its declared n.
#   conservative    — no-cache repricing, 100%-generative query reserve and
#                     photo high-water; still observational, NOT a contract max.
#   contractual_max — deterministic ceiling computed ONLY from ContractualLimits:
#                     every unit on the most expensive permitted route, no cache,
#                     bounded retries at the full output ladder.
#
# Source of truth is the token telemetry (BedrockQuery-shaped rows in
# script/fixtures/gate9_run4_cohort.json); money is always DERIVED via the
# versioned PRICING table below. Never store a computed dollar figure as data.
#
# Reproduces (plan §"Bloque A" item 4, USD):
#   run4 parse ×200 cache     8.6147     retries direct        3.1418
#   run4 parse ×200 no-cache 10.0075     wasted first attempts 1.5348
#   cap-8k cache              5.7869     cap-8k no-cache       6.6615
#   L2 cap-8k cache           6.23       L2 cap-8k no-cache    7.10
class Gate9CostMatrix
  DEFAULT_FIXTURE_PATH = File.expand_path("../../script/fixtures/gate9_run4_cohort.json", __dir__)

  PRICING_VERSION = "2026-06-12"

  # USD per 1,000 tokens. Mirrors BedrockQuery::BEDROCK_PRICING for the model ids
  # used by ingestion/queries (asserted equal by Gate9CostMatrixTest).
  PRICING = {
    "sonnet_direct" => { input: 0.003,   output: 0.015,  cache_read: 0.0003,  cache_creation: 0.00375 },
    "sonnet_batch"  => { input: 0.0015,  output: 0.0075, cache_read: 0.00015, cache_creation: 0.001875 },
    "opus_direct"   => { input: 0.005,   output: 0.025,  cache_read: 0.0005,  cache_creation: 0.00625 },
    "opus_batch"    => { input: 0.0025,  output: 0.0125, cache_read: 0.00025, cache_creation: 0.003125 },
    "haiku_direct"  => { input: 0.001,   output: 0.005,  cache_read: 0.0001,  cache_creation: 0.00125 },
    "haiku_global"  => { input: 0.001,   output: 0.005 },
    "titan_v2"      => { input: 0.00002, output: 0.0 }
  }.freeze

  def initialize(fixture_path: DEFAULT_FIXTURE_PATH)
    @data = JSON.parse(File.read(fixture_path))
  end

  def report
    {
      pricing_version: PRICING_VERSION,
      manual:          manual_scenarios,
      queries:         query_scenarios,
      photos:          photo_scenarios,
      contractual_max: contractual_max
    }
  end

  # ── Manual (run4 cohort scaled ×200/24, sync cache repriced to Batch) ──────
  #
  # First attempts repriced at Batch rates (the L2 route); ladder retries stay
  # at direct rates — Batch retries of truncated pages are billed direct.
  def manual_scenarios
    scale = scale_factor

    firsts  = parse_rows.select { |r| r["attempt"] == 1 }
    retries = parse_rows.select { |r| r["attempt"] > 1 }
    wasted  = firsts.select { |r| r["stop_reason"] == "max_tokens" }

    parse_cache    = total_parse_cost(firsts, retries, cache: true)  * scale
    parse_no_cache = total_parse_cost(firsts, retries, cache: false) * scale

    cap8k_cache    = cap8k_cost(firsts, cache: true)  * scale
    cap8k_no_cache = cap8k_cost(firsts, cache: false) * scale

    filter_cost = filter_rows.sum { |r| row_cost(r, "haiku_direct", cache: true) } * scale
    fixed       = filter_cost + embeddings_cost

    {
      n_pages_cohort:                 @data.dig("metadata", "kept_pages"),
      scale_target_pages:             @data.dig("metadata", "scale_target_pages"),
      expected: {
        parse_x200_cache:             round4(parse_cache),
        retries_direct_x200:          round4(cost_of(retries, repriced: :direct, cache: true) * scale),
        wasted_first_attempts_x200:   round4(cost_of(wasted, repriced: :batch, cache: true) * scale),
        page_filter_x200:             round4(filter_cost),
        embeddings_x200:              round4(embeddings_cost),
        l2_total_cache:               round2(parse_cache + fixed)
      },
      conservative: {
        parse_x200_no_cache:          round4(parse_no_cache),
        l2_total_no_cache:            round2(parse_no_cache + fixed)
      },
      o3_cap8k: {
        parse_x200_cache:             round4(cap8k_cache),
        parse_x200_no_cache:          round4(cap8k_no_cache),
        avoidable_cost_cache:         round4(parse_cache - cap8k_cache),
        avoidable_cost_no_cache:      round4(parse_no_cache - cap8k_no_cache),
        l2_total_cache:               round2(cap8k_cache + fixed),
        l2_total_no_cache:            round2(cap8k_no_cache + fixed)
      },
      splits: {
        sonnet_x200_cache:            round4(cost_of(model_rows("sonnet", firsts), repriced: :batch, cache: true) * scale +
                                             cost_of(model_rows("sonnet", retries), repriced: :direct, cache: true) * scale),
        opus_x200_cache:              round4(cost_of(model_rows("opus", firsts), repriced: :batch, cache: true) * scale +
                                             cost_of(model_rows("opus", retries), repriced: :direct, cache: true) * scale),
        batch_first_attempts_cache:   round4(cost_of(firsts, repriced: :batch, cache: true) * scale),
        direct_retries_cache:         round4(cost_of(retries, repriced: :direct, cache: true) * scale),
        cache_penalty_no_cache_delta: round4(parse_no_cache - parse_cache)
      }
    }
  end

  # ── Queries (certified 16×3 benchmark tokens, Haiku global) ────────────────
  #
  # B.1 paso 13: the commercial basis is CloudWatch tokens. App-side query rows
  # reconstruct input from observable citations (BedrockQuery token_source
  # "estimated") and V1 measured a 29.7% cost underestimation on them — they are
  # never used here except to publish the reconciliation gap itself.
  def query_scenarios
    cert    = @data.fetch("query_certification")
    rates   = PRICING.fetch("haiku_global")
    queries = cert.fetch("queries").to_f
    calls   = cert.fetch("model_calls").to_f

    cert_cost = (cert["input_tokens"] * rates[:input] + cert["output_tokens"] * rates[:output]) / 1000.0

    # Conservative reserve: all 1,000 queries invoke the model at the observed
    # per-call token averages (no deterministic-answer discount).
    per_call = cert_cost / calls

    {
      n_queries:                 queries.to_i,
      n_model_calls:             calls.to_i,
      basis:                     "cloudwatch_tokens",
      expected_per_1000:         round4(cert_cost / queries * 1000),
      conservative_per_1000:     round4(per_call * 1000),
      ledger_reconciliation:     query_ledger_reconciliation
    }
  end

  # V1-measured gap between the app ledger (estimated tokens) and CloudWatch
  # for the same query cohort. Costs derived from fixture tokens, not stored.
  def query_ledger_reconciliation
    recon = @data.fetch("v1_query_ledger_reconciliation")
    rates = PRICING.fetch("haiku_global")

    app_cost = (recon["app_input_tokens"] * rates[:input] +
                recon["app_output_tokens"] * rates[:output]) / 1000.0
    cw_cost  = (recon["cloudwatch_input_tokens"] * rates[:input] +
                recon["cloudwatch_output_tokens"] * rates[:output]) / 1000.0

    {
      source:                      recon["source"],
      app_ledger_cost:             round4(app_cost),
      cloudwatch_cost:             round4(cw_cost),
      app_underestimation_pct:     ((1 - app_cost / cw_cost) * 100).round(1),
      rule:                        "commercial query cost uses CloudWatch tokens; app rows with token_source=estimated are operational diagnosis only"
    }
  end

  # ── Photos (4 v3 parse samples — biased, provisional) ─────────────────────
  def photo_scenarios
    samples    = @data.fetch("photo_samples")
    costs      = samples.fetch("costs_usd")
    embeddings = samples.fetch("embeddings_usd_per_200")

    {
      n:                     samples["n"],
      note:                  samples["note"],
      expected_per_200:      round4(costs.sum / costs.size * 200 + embeddings),
      conservative_per_200:  round4(costs.max * 200 + embeddings)
    }
  end

  # ── Contractual max — deterministic, no-cache, from ContractualLimits ─────
  def contractual_max
    {
      basis:            "ContractualLimits — most expensive permitted route, no cache, bounded retries",
      queries_per_1000: round2(max_query_cost * ContractualLimits::QUERY[:included_per_month]),
      photos_per_200:   round2(max_photo_cost * ContractualLimits::PHOTO[:included_per_month]),
      manual_200pp:     round2(max_manual_cost)
    }
  end

  private

  def scale_factor
    @data.dig("metadata", "scale_target_pages").to_f / @data.dig("metadata", "total_pages")
  end

  def manual_rows  = @data.fetch("manual_cohort_rows")
  def parse_rows   = manual_rows.select { |r| r["route"] == "sync" }
  def filter_rows  = manual_rows.select { |r| r["route"] == "page_filter" }

  def embeddings_cost = @data.dig("manual_fixed_costs", "embeddings_usd_per_200pp").to_f

  def model_rows(kind, rows)
    rows.select { |r| r["model_id"].include?(kind) }
  end

  def model_kind(row)
    row["model_id"].include?("opus") ? "opus" : "sonnet"
  end

  # repriced: :batch | :direct — billing route for the L2 scenario.
  def cost_of(rows, repriced:, cache:)
    rows.sum { |r| row_cost(r, "#{model_kind(r)}_#{repriced}", cache: cache) }
  end

  def total_parse_cost(firsts, retries, cache:)
    cost_of(firsts, repriced: :batch, cache: cache) +
      cost_of(retries, repriced: :direct, cache: cache)
  end

  # O3′ simulation: with an 8k initial cap every run4 page fits in one call —
  # the truncated firsts are replaced by a single Batch-priced call with the
  # first attempt's input/cache profile and the retry's final output size.
  def cap8k_cost(firsts, cache:)
    retry_output_by_page = parse_rows.select { |r| r["attempt"] > 1 }
                                     .to_h { |r| [ r["page"], r["output_tokens"] ] }

    firsts.sum do |row|
      effective = row
      if row["stop_reason"] == "max_tokens" && retry_output_by_page.key?(row["page"])
        effective = row.merge("output_tokens" => retry_output_by_page[row["page"]])
      end
      row_cost(effective, "#{model_kind(row)}_batch", cache: cache)
    end
  end

  # cache: true  — bill cache_read/cache_creation tokens at their special rates.
  # cache: false — contractual no-cache: all input-side tokens at the base rate.
  def row_cost(row, rate_key, cache:)
    rates = PRICING.fetch(rate_key)
    if cache
      (row["input_tokens"].to_i          * rates[:input] +
       row["output_tokens"].to_i         * rates[:output] +
       row["cache_read_tokens"].to_i     * rates.fetch(:cache_read) +
       row["cache_creation_tokens"].to_i * rates.fetch(:cache_creation)) / 1000.0
    else
      ((row["input_tokens"].to_i + row["cache_read_tokens"].to_i + row["cache_creation_tokens"].to_i) *
        rates[:input] +
       row["output_tokens"].to_i * rates[:output]) / 1000.0
    end
  end

  # One query: max_model_calls × (max input + max output) at Haiku global rates.
  def max_query_cost
    limits = ContractualLimits::QUERY
    rates  = PRICING.fetch("haiku_global")
    limits[:max_model_calls] *
      (limits[:max_input_tokens] * rates[:input] + limits[:max_output_tokens] * rates[:output]) / 1000.0
  end

  # One photo: Opus direct (most expensive permitted), full ladder walk, no cache.
  def max_photo_cost
    limits = ContractualLimits::PHOTO
    rates  = PRICING.fetch("opus_direct")
    limits[:output_token_ladder].sum do |cap|
      max_input = limits[:context_window_tokens] - cap
      (max_input * rates[:input] + cap * rates[:output]) / 1000.0
    end
  end

  # One manual: max pages with max permitted Opus fraction; per page one Batch
  # attempt at ladder[0] plus direct retries at the remaining rungs; plus the
  # Haiku filter at max windows × max attempts and the embedding ceiling.
  def max_manual_cost
    limits     = ContractualLimits::MANUAL
    pages      = limits[:max_pages_included]
    opus_pages = (pages * limits[:max_opus_page_fraction]).ceil
    ladder     = limits[:output_token_ladder]
    context    = limits[:context_window_tokens]

    page_max = lambda do |model|
      batch  = PRICING.fetch("#{model}_batch")
      direct = PRICING.fetch("#{model}_direct")
      first_input = context - ladder[0]
      first = (first_input * batch[:input] + ladder[0] * batch[:output]) / 1000.0
      first + ladder[1..].sum do |cap|
        max_input = context - cap
        (max_input * direct[:input] + cap * direct[:output]) / 1000.0
      end
    end

    parse = (pages - opus_pages) * page_max.call("sonnet") + opus_pages * page_max.call("opus")

    haiku   = PRICING.fetch("haiku_direct")
    windows = (pages.to_f / limits[:filter_window_size]).ceil
    filter_input = limits[:max_filter_context_tokens] - limits[:max_filter_output_tokens_per_window]
    filter  = windows * limits[:max_filter_attempts_per_window] *
              (filter_input * haiku[:input] +
               limits[:max_filter_output_tokens_per_window] * haiku[:output]) / 1000.0

    embeddings = limits[:max_embedding_tokens] * PRICING.fetch("titan_v2")[:input] / 1000.0

    parse + filter + embeddings
  end

  def round4(value) = value.round(4)
  def round2(value) = value.round(2)
end
