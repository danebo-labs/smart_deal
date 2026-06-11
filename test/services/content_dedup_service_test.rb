# frozen_string_literal: true

require "test_helper"

class ContentDedupServiceTest < ActiveSupport::TestCase
  CONTRACT = BatchChunkingPrompt::INGESTION_CONTRACT_VERSION

  setup do
    @binary    = "fake binary content for dedup test"
    @sha256    = Digest::SHA256.hexdigest(@binary)
    @custom_id = BulkUploadAsset.custom_id_for_sha(@sha256, contract_version: CONTRACT)
  end

  def create_complete_asset(custom_id: @custom_id, contract_version: CONTRACT)
    bulk_upload = BulkUpload.create!(
      sha256:            Digest::SHA256.hexdigest("batch zip #{custom_id}"),
      original_filename: "batch.zip",
      status:            "complete"
    )
    asset = BulkUploadAsset.create!(
      bulk_upload:    bulk_upload,
      custom_id:      custom_id,
      sha256:         @sha256,
      filename:       "pump.pdf",
      status:         "complete",
      canonical_name: "Orona Pump Manual",
      aliases:        %w[HPM-400 orona],
      ingestion_contract_version: contract_version
    )
    [ asset, bulk_upload ]
  end

  test "same source and same contract version is a hit" do
    asset, bulk_upload = create_complete_asset

    result = ContentDedupService.find_completed(sha256: @sha256, contract_version: CONTRACT)

    assert result.hit
    assert_equal asset, result.asset
    assert_equal "Orona Pump Manual", result.canonical_name
    assert_equal %w[HPM-400 orona], result.aliases
  ensure
    asset&.destroy
    bulk_upload&.destroy
  end

  test "same source under a different contract version is a miss" do
    asset, bulk_upload = create_complete_asset

    result = ContentDedupService.find_completed(sha256: @sha256, contract_version: "field_records_v999")

    assert_not result.hit
  ensure
    asset&.destroy
    bulk_upload&.destroy
  end

  test "legacy asset without contract version is a miss even with legacy custom_id" do
    legacy_custom_id = @sha256[0, 32]
    asset, bulk_upload = create_complete_asset(custom_id: legacy_custom_id, contract_version: nil)

    result = ContentDedupService.find_completed(sha256: @sha256, contract_version: CONTRACT)

    assert_not result.hit
  ensure
    asset&.destroy
    bulk_upload&.destroy
  end

  test "returns miss when no completed asset exists" do
    result = ContentDedupService.find_completed(sha256: @sha256, contract_version: CONTRACT)

    assert_not result.hit
    assert_nil result.asset
    assert_nil result.canonical_name
    assert_empty result.aliases
  end

  test "returns miss when asset status is not complete" do
    bulk_upload = BulkUpload.create!(
      sha256:            Digest::SHA256.hexdigest("batch zip2 #{@sha256}"),
      original_filename: "batch2.zip",
      status:            "processing"
    )
    BulkUploadAsset.create!(
      bulk_upload: bulk_upload,
      custom_id:   @custom_id,
      sha256:      @sha256,
      filename:    "pump.pdf",
      status:      "in_batch",
      ingestion_contract_version: CONTRACT
    )

    result = ContentDedupService.find_completed(sha256: @sha256, contract_version: CONTRACT)

    assert_not result.hit
  ensure
    BulkUploadAsset.find_by(custom_id: @custom_id)&.destroy
    bulk_upload&.destroy
  end

  test "custom_id is contract-versioned and stable" do
    v1 = BulkUploadAsset.custom_id_for(@binary, contract_version: "a")
    v2 = BulkUploadAsset.custom_id_for(@binary, contract_version: "b")

    assert_equal 32, v1.length
    assert_not_equal v1, v2
    assert_equal v1, BulkUploadAsset.custom_id_for_sha(@sha256, contract_version: "a")
  end
end
