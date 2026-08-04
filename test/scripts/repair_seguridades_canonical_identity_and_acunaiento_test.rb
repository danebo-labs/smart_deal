# frozen_string_literal: true

require "test_helper"

# Ciclo 5 Fase 1 (H1/H2): this repair script originally had no
# Rag::SectionNeighborExpander cache invalidation hook, so its corrected
# canonical_name kept being shadowed by a stale Rails.cache entry for up to
# 30 days. Source-only assertions on purpose: the script `abort`s at load
# time unless RAG_CHUNK_PATCH_CONFIRM=1 and then talks to real AWS — it must
# never be `require`d from a test.
class RepairSeguridadesCanonicalIdentityAndAcunaientoTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb").read.freeze

  test "invokes Rag::SectionNeighborExpander.invalidate! on the document's exact chunk prefix" do
    assert_match(/Rag::SectionNeighborExpander\.invalidate!\(CHUNK_PREFIX\)/, SOURCE)
  end

  test "invalidate! runs after the ingestion job reaches COMPLETE, not before (H8)" do
    resync_guard_index = SOURCE.index('abort("KB ingestion job ended')
    invalidate_call_index = SOURCE.index("Rag::SectionNeighborExpander.invalidate!")

    assert resync_guard_index, "expected the KB sync completion guard to still be present"
    assert invalidate_call_index, "expected the invalidate! call to be present"
    assert_operator invalidate_call_index, :>, resync_guard_index,
      "invalidate! must run after the resync completes, otherwise it would rebuild the index from pre-repair S3 state"
  end
end
