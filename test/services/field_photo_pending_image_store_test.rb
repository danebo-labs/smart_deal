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

  test "round-trips thumbnail fields when provided" do
    token = FieldPhotoPendingImageStore.write(
      binary: "raw", content_type: "image/jpeg", filename: "panel.jpg", account_id: 1,
      thumbnail_binary: "thumb-bytes", thumbnail_content_type: "image/jpeg",
      thumbnail_width: 88, thumbnail_height: 66
    )

    payload = FieldPhotoPendingImageStore.take(token: token, account_id: 1)
    assert_equal "thumb-bytes", payload[:thumbnail_binary]
    assert_equal "image/jpeg", payload[:thumbnail_content_type]
    assert_equal 88, payload[:thumbnail_width]
    assert_equal 66, payload[:thumbnail_height]
  end

  test "thumbnail fields are backward compatible when omitted" do
    token = FieldPhotoPendingImageStore.write(
      binary: "raw", content_type: "image/jpeg", filename: "panel.jpg", account_id: 1
    )

    payload = FieldPhotoPendingImageStore.take(token: token, account_id: 1)
    assert_nil payload[:thumbnail_binary]
    assert_nil payload[:thumbnail_content_type]
    assert_nil payload[:thumbnail_width]
    assert_nil payload[:thumbnail_height]
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
