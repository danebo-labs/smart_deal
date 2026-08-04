# frozen_string_literal: true

require "test_helper"

# Ciclo 5 Fase 1 (H1/H2): this repair script originally had no
# Rag::SectionNeighborExpander cache invalidation hook, so its corrected
# canonical_name kept being shadowed by a stale Rails.cache entry for up to
# 30 days. The fix moved to S3DocumentsService (every #upload_text/
# #upload_binary write under bulk_chunks/ invalidates automatically — see
# app/services/s3_documents_service_test.rb), so this script needs no
# explicit invalidate! call as long as it keeps writing through
# S3DocumentsService. Source-only assertions on purpose: the script
# `abort`s at load time unless RAG_CHUNK_PATCH_CONFIRM=1 and then talks to
# real AWS — it must never be `require`d from a test.
class RepairSeguridadesCanonicalIdentityAndAcunaientoTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb").read.freeze

  test "writes both the sidecars and the chunk body through S3DocumentsService, not raw Aws::S3::Client" do
    assert_match(/s3\.upload_text\(.*r\[:sidecar_name\]/, SOURCE)
    assert_match(/s3\.upload_text\(body_record\[:key\]/, SOURCE)
    assert_no_match(/raw_s3\.put_object/, SOURCE,
      "a write via raw_s3 (Aws::S3::Client) would bypass S3DocumentsService's automatic cache invalidation")
  end

  test "documents why no explicit invalidate! call is needed here (H1/H2)" do
    assert_match(/S3DocumentsService#upload_text/, SOURCE)
    assert_match(/Rag::SectionNeighborExpander\.invalidate!/, SOURCE)
  end
end
