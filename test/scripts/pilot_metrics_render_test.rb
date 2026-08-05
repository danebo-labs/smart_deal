# frozen_string_literal: true

require "test_helper"
require "tempfile"

class PilotMetricsRenderTest < ActiveSupport::TestCase
  test "renders report JSON locally through the pure human formatter" do
    file = Tempfile.new([ "pilot-report", ".json" ])
    file.write(JSON.generate(
      date: "2026-07-22",
      timezone: "America/Santiago",
      generated_at: "2026-07-23T00:00:00-04:00",
      technical_and_cost: {
        totals: {
          rag_llm_calls: 0,
          visual_llm_calls: 0,
          photo_cache_hits: nil,
          visual_llm_calls_avoided: nil,
          photo_cache_hit_rate: nil,
          input_tokens: 0,
          output_tokens: 0,
          attributed_cost_usd: 0,
          provider_usage_usd: 0,
          estimated_usd: 0,
          estimated_cost_avoided: nil
        },
        per_user: [],
        per_account: []
      }
    ))
    file.flush
    previous_argv = ARGV.dup
    ARGV.replace([ file.path ])

    stdout, _stderr = capture_io do
      load Rails.root.join("script/pilot_metrics_render.rb")
    end

    assert_match(/Pilot metrics — 2026-07-22 \(America\/Santiago\)/, stdout)
    assert_match(/Attributed cost: \$0\.000000/, stdout)
  ensure
    ARGV.replace(previous_argv) if previous_argv
    file&.close!
  end
end
