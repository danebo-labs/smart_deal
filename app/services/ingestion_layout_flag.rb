# frozen_string_literal: true

# Rollback switch for the contract v8 topology-edge pipeline
# (docs/rag/plan_conocimiento_visual.md, Fase 4). Off means: no LAYOUT DIGEST
# block reaches the ingestion prompt, no TOPOLOGY_EDGE field record is
# rendered into a chunk body, and no `section_path` / `topology_edge_count`
# key is written to a sidecar — chunk bodies and sidecars stay byte-identical
# to the v7 contract. Per the human decision #4 (opción B, 2026-08-01), Fase 4
# ships and merges with this flag OFF; the shadow re-ingest (Fase 7) waits for
# the vision tier (Fase 5) and the Gate B calibration.
module IngestionLayoutFlag
  module_function

  def enabled?
    ENV["INGESTION_LAYOUT_DIGEST_ENABLED"] == "true"
  end
end
