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

  # Second switch, added by the Gate B verdict
  # (docs/rag/gate_b_calibracion_vision.md): T2 may run and still not be allowed
  # to state a relation.
  #
  # Measured on 102 relations judged one by one against the rendered page: T2's
  # relations reach 88.2 % precision, 95 % lower bound 81.6 %, under the 85 %
  # the gate requires — and 81.5 % (lower bound 71.8 %) on the lámina type where
  # a conductor has to be matched to one cell of a dense row of terminals. Its
  # NON-relational output does clear the bar: 38 of 38 component identities
  # correct, lower bound 92.4 %.
  #
  # So the default is the degradation the plan wrote down as acceptable: T2
  # contributes `documented_components` and nothing else; every `TOPOLOGY_EDGE`
  # in a chunk body comes from T1. Turning this on re-enables vision relations
  # and is only defensible once a prompt version has been measured past the bar.
  def relations_enabled?
    ENV["INGESTION_VISION_TIER_RELATIONS_ENABLED"] == "true"
  end

  # Fase 5b, the experiment the Gate B verdict pointed at
  # (docs/rag/gate_b_calibracion_vision.md §10): send the page also as
  # overlapping 300 dpi tiles, because the errors that sank the gate all
  # resolved by hand at that resolution and none of them is locatable from the
  # layout — the cell names are pixels inside the picture of the strip.
  #
  # Off by default, and it must stay off until someone measures it: it raises
  # the cost per page by roughly half and its effect on precision is a
  # hypothesis, not a number.
  def zoom_tiles_enabled?
    ENV["INGESTION_VISION_TIER_ZOOM_TILES"] == "true"
  end
end
