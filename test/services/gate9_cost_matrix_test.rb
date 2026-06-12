# frozen_string_literal: true

require "test_helper"
require "socket"

class Gate9CostMatrixTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  def report
    @report ||= Gate9CostMatrix.new.report
  end

  # ── Plan figures (Bloque A item 4 — exact reproduction) ───────────────────

  test "reproduces run4 parse ×200 with observed cache: $8.6147" do
    assert_equal 8.6147, report[:manual][:expected][:parse_x200_cache]
  end

  test "reproduces run4 parse ×200 no-cache: $10.0075" do
    assert_equal 10.0075, report[:manual][:conservative][:parse_x200_no_cache]
  end

  test "reproduces direct retries mass: $3.1418" do
    assert_equal 3.1418, report[:manual][:expected][:retries_direct_x200]
  end

  test "reproduces wasted truncated first attempts: $1.5348" do
    assert_equal 1.5348, report[:manual][:expected][:wasted_first_attempts_x200]
  end

  test "reproduces O3' cap-8k parse: $5.7869 cache / $6.6615 no-cache" do
    assert_equal 5.7869, report[:manual][:o3_cap8k][:parse_x200_cache]
    assert_equal 6.6615, report[:manual][:o3_cap8k][:parse_x200_no_cache]
  end

  test "reproduces O3' avoidable cost: $2.8278 cache / $3.3460 no-cache" do
    assert_equal 2.8278, report[:manual][:o3_cap8k][:avoidable_cost_cache]
    assert_equal 3.346,  report[:manual][:o3_cap8k][:avoidable_cost_no_cache]
  end

  test "reproduces L2 cap-8k totals: $6.23 cache / $7.10 no-cache" do
    assert_equal 6.23, report[:manual][:o3_cap8k][:l2_total_cache]
    assert_equal 7.1,  report[:manual][:o3_cap8k][:l2_total_no_cache]
  end

  test "reproduces published provisional baseline: L2 $9.05 and 4k no-cache $10.45" do
    assert_equal 9.05,  report[:manual][:expected][:l2_total_cache]
    assert_equal 10.45, report[:manual][:conservative][:l2_total_no_cache]
  end

  test "reproduces SAAS_COST_MODEL component split: Sonnet $4.8589 / Opus $3.7558 / filter $0.4316" do
    assert_equal 4.8589, report[:manual][:splits][:sonnet_x200_cache]
    assert_equal 3.7558, report[:manual][:splits][:opus_x200_cache]
    assert_equal 0.4316, report[:manual][:expected][:page_filter_x200]
  end

  test "reproduces query baseline: $6.4867 certified mix / $8.6490 full-generative reserve" do
    assert_equal 6.4867, report[:queries][:expected_per_1000]
    assert_equal 8.649,  report[:queries][:conservative_per_1000]
  end

  test "reproduces photo baseline: $4.6237 expected / $5.2276 high-water (n=4 declared)" do
    assert_equal 4.6237, report[:photos][:expected_per_200]
    assert_equal 5.2276, report[:photos][:conservative_per_200]
    assert_equal 4, report[:photos][:n]
  end

  # ── Scenario structure ─────────────────────────────────────────────────────

  test "separates first/retry/wasted, Batch/direct and cache/no-cache dimensions" do
    manual = report[:manual]

    assert_operator manual[:splits][:batch_first_attempts_cache], :>, 0
    assert_operator manual[:splits][:direct_retries_cache], :>, 0
    assert_operator manual[:splits][:cache_penalty_no_cache_delta], :>, 0
    # retries + wasted are subsets of the full parse mass
    assert_operator manual[:expected][:retries_direct_x200] + manual[:expected][:wasted_first_attempts_x200],
                    :<, manual[:expected][:parse_x200_cache]
    # batch firsts + direct retries == full parse mass (cache scenario)
    assert_in_delta manual[:expected][:parse_x200_cache],
                    manual[:splits][:batch_first_attempts_cache] + manual[:splits][:direct_retries_cache],
                    0.0001
    # Sonnet + Opus == full parse mass
    assert_in_delta manual[:expected][:parse_x200_cache],
                    manual[:splits][:sonnet_x200_cache] + manual[:splits][:opus_x200_cache],
                    0.0001
  end

  test "contractual max is finite, no-cache and derived from ContractualLimits" do
    cmax = report[:contractual_max]

    [ :queries_per_1000, :photos_per_200, :manual_200pp ].each do |key|
      assert cmax[key].finite?, "#{key} must be finite"
      assert_operator cmax[key], :>, 0
    end

    # Deterministic recomputation from the limits (independent arithmetic).
    q = ContractualLimits::QUERY
    expected_query = q[:max_model_calls] * (q[:max_input_tokens] * 0.001 + q[:max_output_tokens] * 0.005) / 1000.0 * q[:included_per_month]
    assert_in_delta expected_query, cmax[:queries_per_1000], 0.01

    p = ContractualLimits::PHOTO
    per_photo = p[:output_token_ladder].sum do |cap|
      ((p[:context_window_tokens] - cap) * 0.005 + cap * 0.025) / 1000.0
    end
    assert_in_delta per_photo * p[:included_per_month], cmax[:photos_per_200], 0.01

    # Contractual max strictly dominates the conservative observational scenario.
    assert_operator cmax[:manual_200pp], :>, report[:manual][:conservative][:l2_total_no_cache]
    assert_operator cmax[:queries_per_1000], :>, report[:queries][:conservative_per_1000]
    assert_operator cmax[:photos_per_200], :>, report[:photos][:conservative_per_200]
  end

  # ── Pricing consistency (versioned prices are the single derivation source) ─

  test "matrix pricing matches BedrockQuery::BEDROCK_PRICING for billable model ids" do
    {
      "sonnet_direct" => "claude-sonnet-4-6-direct",
      "sonnet_batch"  => "claude-sonnet-4-6-batch",
      "opus_direct"   => "claude-opus-4-8-direct",
      "opus_batch"    => "claude-opus-4-8-batch",
      "haiku_direct"  => "claude-haiku-4-5-20251001-direct",
      "titan_v2"      => "amazon.titan-embed-text-v2:0"
    }.each do |matrix_key, model_id|
      matrix_rates = Gate9CostMatrix::PRICING.fetch(matrix_key)
      model_rates  = BedrockQuery::BEDROCK_PRICING.fetch(model_id)

      assert_equal model_rates[:input],  matrix_rates[:input],  "#{matrix_key} input rate drifted"
      assert_equal model_rates[:output], matrix_rates[:output], "#{matrix_key} output rate drifted"
      if model_rates[:cache_read]
        assert_equal model_rates[:cache_read],     matrix_rates[:cache_read],     "#{matrix_key} cache_read rate drifted"
        assert_equal model_rates[:cache_creation], matrix_rates[:cache_creation], "#{matrix_key} cache_creation rate drifted"
      end
    end
  end

  test "fixture stores tokens and metadata, never derived dollar amounts, for the manual cohort" do
    fixture = JSON.parse(File.read(Gate9CostMatrix::DEFAULT_FIXTURE_PATH))

    fixture.fetch("manual_cohort_rows").each do |row|
      assert row.key?("input_tokens") && row.key?("output_tokens"), "rows must carry token counts"
      assert row.key?("route") && row.key?("attempt") && row.key?("stop_reason"), "rows must carry I0 metadata"
      assert_nil row["cost"], "rows must not store derived cost"
      assert_nil row["cost_usd"], "rows must not store derived cost"
    end

    parse_rows = fixture["manual_cohort_rows"].select { |r| r["route"] == "sync" }
    assert_equal 26, parse_rows.size
    assert_equal 3,  parse_rows.count { |r| r["attempt"] > 1 }, "run4 had exactly 3 ladder retries"
    assert_equal [ 4219, 5233, 5650 ],
                 parse_rows.select { |r| r["attempt"] > 1 }.pluck("output_tokens").sort,
                 "final outputs of the 3 retried pages (plan O3′ evidence)"
  end

  # ── No network calls ───────────────────────────────────────────────────────

  test "builds the full report without opening any network connection" do
    tcp_original  = TCPSocket.method(:open)
    http_original = Net::HTTP.method(:start)

    TCPSocket.define_singleton_method(:open) { |*| raise "network call attempted (TCPSocket)" }
    Net::HTTP.define_singleton_method(:start) { |*| raise "network call attempted (Net::HTTP)" }

    full_report = Gate9CostMatrix.new.report
    assert_equal 8.6147, full_report[:manual][:expected][:parse_x200_cache]
  ensure
    TCPSocket.define_singleton_method(:open, tcp_original)
    Net::HTTP.define_singleton_method(:start, http_original)
  end
end
