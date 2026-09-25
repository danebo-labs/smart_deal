# frozen_string_literal: true

module Rag
  # Percentiles of one clock. Never adds a p95 from one phase to another.
  module PhaseLatency
    module_function

    def percentile(samples, pct)
      values = Array(samples).map(&:to_f).sort
      return nil if values.empty?

      rank = ((pct / 100.0) * (values.length - 1)).round
      values[rank]
    end
  end
end
