# frozen_string_literal: true

# Rollback switch for the visual-complexity triage added on top of the existing
# PageRelevanceFilter Haiku batch call and the FileMultimodalRouter page gate
# (docs/rag/plan_conocimiento_visual.md, Fase 1). Off means: the Haiku batch
# prompt/schema and FileMultimodalRouter#route_page are byte-identical to the
# pre-Fase-1 behavior — no extra schema fields, no second Opus trigger, no
# budget cap.
module IngestionVisualTriageFlag
  module_function

  def enabled?
    ENV["INGESTION_VISUAL_TRIAGE_ENABLED"] == "true"
  end
end
