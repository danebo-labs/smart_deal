# frozen_string_literal: true

# Asynchronously enriches KbDocument rows with canonical names + aliases that
# Haiku discovered in <DOC_REFS>. Moved off the request path so RagController#ask
# can return JSON as soon as Bedrock answers — enrichment is eventually consistent
# (next page refresh / next KbSyncChannel broadcast picks up new aliases).
#
# Idempotency: the underlying KbDocumentEnrichmentService merges aliases via a
# `.uniq.first(15)` pipeline and only saves when changed, so safe to re-run.
class KbDocumentEnrichmentJob < ApplicationJob
  queue_as :default

  # @param doc_refs       [Array<Hash>] Haiku <DOC_REFS> JSON parsed by BedrockRagService
  # @param retrieved_meta [Array<Hash>] minimal citations: { metadata:, location: } only.
  #   Chunk content is intentionally stripped before enqueue to keep the
  #   solid_queue_jobs.arguments payload small (≤ a few KB instead of ~100 KB).
  def perform(doc_refs:, retrieved_meta: [])
    KbDocumentEnrichmentService.new.call(
      doc_refs:      doc_refs,
      all_retrieved: retrieved_meta
    )
  end
end
