# frozen_string_literal: true

require "test_helper"

class BulkUploadTest < ActiveSupport::TestCase
  def create_bulk(sha_suffix: SecureRandom.hex(8))
    BulkUpload.create!(
      sha256:            Digest::SHA256.hexdigest("bulk_#{sha_suffix}"),
      original_filename: "test.zip",
      status:            "processing"
    )
  end

  def add_asset(bulk_upload, status:, filename: "file_#{SecureRandom.hex(4)}.jpg")
    BulkUploadAsset.create!(
      bulk_upload: bulk_upload,
      custom_id:   Digest::SHA256.hexdigest("#{bulk_upload.id}_#{filename}")[0, 32],
      sha256:      Digest::SHA256.hexdigest("#{bulk_upload.id}_#{filename}"),
      filename:    filename,
      status:      status
    )
  end

  teardown do
    BulkUploadAsset.delete_all
    BulkUpload.delete_all
  end

  test "derive_status! → complete when all assets complete" do
    bulk = create_bulk
    add_asset(bulk, status: "complete")
    add_asset(bulk, status: "complete")

    bulk.derive_status!

    assert_equal "complete", bulk.reload.status
    assert_nil bulk.error_message
  end

  test "derive_status! → failed when all assets failed and none complete" do
    bulk = create_bulk
    add_asset(bulk, status: "failed")
    add_asset(bulk, status: "failed")

    bulk.derive_status!

    assert_equal "failed", bulk.reload.status
  end

  test "derive_status! → processing when some assets still in flight" do
    bulk = create_bulk
    add_asset(bulk, status: "complete")
    add_asset(bulk, status: "uploaded_s3")

    bulk.derive_status!

    assert_equal "processing", bulk.reload.status
  end

  test "derive_status! → complete with partial_complete message when mix of complete+failed" do
    bulk = create_bulk
    add_asset(bulk, status: "complete")
    add_asset(bulk, status: "complete")
    add_asset(bulk, status: "failed")

    bulk.derive_status!
    bulk.reload

    assert_equal "complete", bulk.status
    assert_not_nil bulk.error_message
    assert_match(/2/, bulk.error_message)
    assert_match(/1/, bulk.error_message)
  end

  test "derive_status! → pending when no assets" do
    bulk = create_bulk

    bulk.derive_status!

    assert_equal "pending", bulk.reload.status
  end

  test "derive_status! does not overwrite status when unchanged" do
    bulk = BulkUpload.create!(
      sha256:            Digest::SHA256.hexdigest("bulk_static"),
      original_filename: "test.zip",
      status:            "complete"
    )
    add_asset(bulk, status: "complete")

    assert_no_difference -> { bulk.reload.updated_at } do
      bulk.derive_status!
    end
  end
end
