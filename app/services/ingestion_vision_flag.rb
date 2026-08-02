# frozen_string_literal: true

# Rollback switch for the T2 vision tier (docs/rag/plan_conocimiento_visual.md,
# Fase 5). Off means: no page is rasterized, no crop is cut, no vision call is
# billed and no `TOPOLOGY_EDGE` record with `DERIVATION: vision` reaches a chunk
# body — ingestion is byte-identical to the state Fase 4 merged.
#
# Independent of IngestionLayoutFlag on purpose: T1 (deterministic geometry, ~0
# cost) and T2 (one Opus vision call per eligible page) have nothing in common
# except the contract v8 record they both write, so they roll back separately.
# BatchResultsParserService renders that record when EITHER tier is on.
module IngestionVisionFlag
  module_function

  def enabled?
    ENV["INGESTION_VISION_TIER_ENABLED"] == "true"
  end
end
