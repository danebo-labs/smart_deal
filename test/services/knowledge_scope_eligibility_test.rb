# frozen_string_literal: true

require "test_helper"

class KnowledgeScopeEligibilityTest < ActiveSupport::TestCase
  setup do
    @owner = accounts(:legacy)
    @document = KbDocument.create!(
      account: @owner,
      s3_key: "manuals/eligibility.pdf",
      display_name: "Eligibility",
      aliases: []
    )
  end

  test "slug and an uncontrolled account cannot approve" do
    assert_equal false, @owner.danebo_controlled
    error = assert_raises(KnowledgeScopeEligibility::Denied) { approve!(@document) }

    assert_includes error.reasons, "account_not_danebo_controlled"
    assert_equal "tenant_private", @document.reload.knowledge_scope
    assert_equal 0, KnowledgeScopeChange.count
  end

  test "a controlled manual with no ingestion ledger cannot be generalized" do
    @owner.update!(danebo_controlled: true)

    assert_includes KnowledgeScopeEligibility.blocking_reasons(@document), "not_indexed"
    error = assert_raises(KnowledgeScopeEligibility::Denied) { approve!(@document) }

    assert_includes error.reasons, "not_indexed"
    assert_equal "tenant_private", @document.reload.knowledge_scope
    assert_equal 0, KnowledgeScopeChange.count
  end

  test "a field photo key and a field photo ingestion path are rejected" do
    @owner.update!(danebo_controlled: true)
    photo = KbDocument.create!(
      account: @owner,
      s3_key: "field_photos/#{@owner.id}/abc/original.jpg",
      display_name: "Photo",
      aliases: []
    )
    manual = KbDocument.create!(
      account: @owner,
      s3_key: "manuals/photo-asset.pdf",
      display_name: "Photo asset",
      aliases: []
    )
    bulk = BulkUpload.create!(sha256: Digest::SHA256.hexdigest("photo-asset"), original_filename: "p.zip", status: "complete")
    BulkUploadAsset.create!(
      bulk_upload: bulk,
      kb_document: manual,
      custom_id: SecureRandom.hex(16),
      sha256: Digest::SHA256.hexdigest("photo-bytes"),
      filename: "plate.jpg",
      status: "complete",
      ingestion_path: "field_photo_v1",
      chunks_s3_prefix: "bulk_chunks/photo"
    )

    assert_includes KnowledgeScopeEligibility.blocking_reasons(photo), "field_photo"
    assert_includes KnowledgeScopeEligibility.blocking_reasons(manual), "field_photo"
    assert_raises(KnowledgeScopeEligibility::Denied) { approve!(photo) }
    assert_equal "tenant_private", photo.reload.knowledge_scope
  end

  test "an unfinished ledger blocks approval and a complete manual batch does not" do
    @owner.update!(danebo_controlled: true)
    pending = WebManualBatch.create!(
      account: @owner, kb_document: @document, s3_key: @document.s3_key, filename: "eligibility.pdf",
      sha256: SecureRandom.hex(32), ingestion_contract_version: "v1", status: "parsing"
    )

    assert_includes KnowledgeScopeEligibility.blocking_reasons(@document), "not_indexed"
    assert_raises(KnowledgeScopeEligibility::Denied) { approve!(@document) }

    pending.update!(status: "complete")

    assert_includes KnowledgeScopeEligibility.blocking_reasons(@document), "not_indexed"

    pending.update!(chunks_s3_prefix: "bulk_chunks/#{@document.id}")

    assert_empty KnowledgeScopeEligibility.blocking_reasons(@document)
  end

  test "urgent completion alone is not an index" do
    @owner.update!(danebo_controlled: true)
    WebManualBatch.create!(
      account: @owner, kb_document: @document, s3_key: @document.s3_key, filename: "eligibility.pdf",
      sha256: SecureRandom.hex(32), ingestion_contract_version: "v1", status: "syncing",
      urgent_status: "complete"
    )

    assert_includes KnowledgeScopeEligibility.blocking_reasons(@document), "not_indexed"
  end

  test "a shared document_uid or s3_key cannot be approved" do
    @owner.update!(danebo_controlled: true)
    KbDocument.create!(
      account: accounts(:climb),
      document_uid: @document.document_uid,
      s3_key: "manuals/other-uid.pdf",
      display_name: "Other uid",
      aliases: []
    )

    assert_includes KnowledgeScopeEligibility.blocking_reasons(@document), "ambiguous_document_uid"

    unique = KbDocument.create!(
      account: @owner,
      s3_key: "manuals/same-key.pdf",
      display_name: "Same key",
      aliases: []
    )
    KbDocument.create!(
      account: accounts(:climb),
      s3_key: unique.s3_key,
      display_name: "Same key other",
      aliases: []
    )

    assert_includes KnowledgeScopeEligibility.blocking_reasons(unique), "ambiguous_s3_key"
    assert_raises(KnowledgeScopeEligibility::Denied) { approve!(unique) }
    assert_equal "tenant_private", unique.reload.knowledge_scope
  end

  test "revoke does not require the source account to stay controlled" do
    @owner.update!(danebo_controlled: true)
    index_manual_for_retrieval!(@document)
    approve!(@document)
    @owner.update!(danebo_controlled: false)

    KnowledgeScopeChange.apply!(
      kb_document: @document, to_scope: "tenant_private", actor: "ops", reason: "withdrawn"
    )

    assert_equal "tenant_private", @document.reload.knowledge_scope
  end

  private

  def approve!(document)
    KnowledgeScopeChange.apply!(
      kb_document: document, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )
  end
end
