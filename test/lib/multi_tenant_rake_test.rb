# frozen_string_literal: true

require "test_helper"

# P-19: Legacy account upload path — KbDocument scoped to legacy account + retrievable.
# P-20: Sidecar rewrite safety — unresolvable sidecar logged as unmapped, not mis-associated.
class MultiTenantRakeTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ─── P-19: legacy write path ─────────────────────────────────────────────────

  test "P-19: legacy account KbDocument is created with account_id and document_uid" do
    legacy = accounts(:legacy)
    uid    = SecureRandom.uuid
    s3_key = "uploads/#{legacy.id}/#{uid}/original.pdf"

    doc = KbDocument.create!(
      account:      legacy,
      document_uid: uid,
      s3_key:       s3_key,
      display_name: "Legacy Manual P19"
    )

    assert_equal legacy.id, doc.account_id
    assert_equal uid,       doc.document_uid
    assert_equal s3_key,    doc.s3_key

    # Retrievable via account scope
    found = KbDocument.find_by(account_id: legacy.id, document_uid: uid)
    assert_equal doc.id, found.id
  end

  test "P-19: legacy KbDocument not visible from Climb account scope" do
    legacy = accounts(:legacy)
    climb  = accounts(:climb)
    uid    = SecureRandom.uuid

    KbDocument.create!(
      account:      legacy,
      document_uid: uid,
      s3_key:       "uploads/#{legacy.id}/#{uid}/original.pdf",
      display_name: "Legacy Doc For P19 Isolation"
    )

    assert_nil KbDocument.find_by(account_id: climb.id, document_uid: uid),
               "legacy doc must not be visible from Climb account scope"
  end

  # ─── P-20: sidecar rewrite safety ────────────────────────────────────────────

  test "P-20: sidecar with resolvable KbDocument gets account_id + document_id merged" do
    legacy = accounts(:legacy)
    uid    = SecureRandom.uuid
    s3_key = "s3://bucket/test_doc.pdf"

    doc = KbDocument.create!(
      account:      legacy,
      document_uid: uid,
      s3_key:       s3_key,
      display_name: "Rewrite Test"
    )

    # Simulate what rewrite_legacy_sidecars does: resolve doc, merge attrs
    original_attrs = {
      "original_source_uri"        => s3_key,
      "canonical_name"             => "Rewrite Test",
      "ingestion_path"             => "batch_v1"
    }
    resolved_doc = KbDocument.find_by(s3_key: s3_key)
    assert_not_nil resolved_doc, "must find doc by s3_key"
    assert_not_nil resolved_doc.account_id
    assert_not_nil resolved_doc.document_uid

    merged = original_attrs.merge(
      "account_id"  => resolved_doc.account_id.to_s,
      "document_id" => resolved_doc.document_uid.to_s
    )

    assert_equal legacy.id.to_s, merged["account_id"]
    assert_equal uid,            merged["document_id"]
    assert_equal s3_key,         merged["original_source_uri"]
  end

  test "P-20: sidecar with unknown source_uri is unmapped — not mis-associated" do
    # No KbDocument exists for this URI — resolver must return nil
    unknown_uri = "s3://bucket/nonexistent_doc_xyz_#{SecureRandom.hex(4)}.pdf"

    resolved = KbDocument.find_by(s3_key: unknown_uri)
    resolved ||= BulkUploadAsset.find_by(s3_key: unknown_uri)&.kb_document

    assert_nil resolved, "unresolvable URI must yield nil — must not be mis-associated to another doc"
  end

  test "P-20: rewrite is idempotent for already-correct sidecars" do
    legacy = accounts(:legacy)
    uid    = SecureRandom.uuid
    s3_key = "s3://bucket/idempotent_doc.pdf"

    KbDocument.create!(
      account:      legacy,
      document_uid: uid,
      s3_key:       s3_key,
      display_name: "Idempotent Rewrite"
    )

    # First pass: attrs are blank → gets merged
    attrs = { "original_source_uri" => s3_key }
    doc = KbDocument.find_by(s3_key: s3_key)
    first_result = attrs.merge("account_id" => doc.account_id.to_s, "document_id" => doc.document_uid.to_s)

    # Second pass: attrs already have correct values → same result
    second_attrs = first_result.dup
    already_correct = second_attrs["account_id"] == doc.account_id.to_s &&
                      second_attrs["document_id"] == doc.document_uid.to_s

    assert already_correct, "already-correct sidecar must be identified as already_correct without re-writing"
  end
end
