# frozen_string_literal: true

require "test_helper"

class FieldPhotoPendingImageStoreTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
    ENV.delete("PHOTO_PENDING_IMAGE_TTL_MINUTES")
  end

  test "write and take return sanitized payload once" do
    token = FieldPhotoPendingImageStore.write(
      binary: "raw",
      content_type: "image/jpeg",
      filename: "../panel.jpg",
      account_id: 1
    )

    assert_operator token.length, :>=, 32
    payload = FieldPhotoPendingImageStore.take(token: token, account_id: 1)
    assert_equal "raw", payload[:binary]
    assert_equal "panel.jpg", payload[:filename]
    assert_nil FieldPhotoPendingImageStore.take(token: token, account_id: 1)
  end

  test "same token cannot be read through another account key" do
    token = FieldPhotoPendingImageStore.write(
      binary: "raw", content_type: "image/jpeg", filename: "panel.jpg", account_id: 1
    )

    assert_nil FieldPhotoPendingImageStore.take(token: token, account_id: 2)
    assert_equal "raw", FieldPhotoPendingImageStore.take(token: token, account_id: 1)[:binary]
  end

  test "expired payload returns nil" do
    ENV["PHOTO_PENDING_IMAGE_TTL_MINUTES"] = "0.00001"
    token = FieldPhotoPendingImageStore.write(
      binary: "raw", content_type: "image/jpeg", filename: "panel.jpg", account_id: 1
    )
    sleep 0.01

    assert_nil FieldPhotoPendingImageStore.take(token: token, account_id: 1)
  end
end
