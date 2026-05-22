# frozen_string_literal: true

require "test_helper"

class ContentDedupServiceTest < ActiveSupport::TestCase
  setup do
    @binary    = "fake binary content for dedup test"
    @sha256    = Digest::SHA256.hexdigest(@binary)
    @custom_id = @sha256[0, 32]
  end

  test "returns hit when completed asset exists with matching custom_id" do
    bulk_upload = BulkUpload.create!(
      sha256:            Digest::SHA256.hexdigest("batch zip #{@sha256}"),
      original_filename: "batch.zip",
      status:            "complete"
    )
    asset = BulkUploadAsset.create!(
      bulk_upload:    bulk_upload,
      custom_id:      @custom_id,
      sha256:         @sha256,
      filename:       "pump.pdf",
      status:         "complete",
      canonical_name: "Orona Pump Manual",
      aliases:        %w[HPM-400 orona]
    )

    result = ContentDedupService.find_completed(sha256: @sha256)

    assert result.hit
    assert_equal asset, result.asset
    assert_equal "Orona Pump Manual", result.canonical_name
    assert_equal %w[HPM-400 orona], result.aliases
  ensure
    asset&.destroy
    bulk_upload&.destroy
  end

  test "returns miss when no completed asset exists" do
    result = ContentDedupService.find_completed(sha256: @sha256)

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
      status:      "in_batch"
    )

    result = ContentDedupService.find_completed(sha256: @sha256)

    assert_not result.hit
  ensure
    BulkUploadAsset.find_by(custom_id: @custom_id)&.destroy
    bulk_upload&.destroy
  end
end
