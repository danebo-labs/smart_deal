# frozen_string_literal: true

require "test_helper"

class FieldPhotoStoreTest < ActiveSupport::TestCase
  def make_account
    Account.create!(display_name: "Field Photo Store Co", slug: "field-photo-store-#{SecureRandom.hex(4)}")
  end

  class FakeS3
    attr_reader :uploads, :downloads

    def initialize(upload_succeeds: true)
      @upload_succeeds = upload_succeeds
      @uploads = []
      @downloads = []
    end

    def upload_binary(key, data, content_type)
      @uploads << { key: key, data: data, content_type: content_type }
      @upload_succeeds ? key : nil
    end

    def download(key)
      @downloads << key
      "original-bytes"
    end
  end

  def with_fake_s3(fake)
    orig = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { fake }
    yield
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
  end

  test "creates a row and uploads to S3 the first time" do
    account = make_account
    fake = FakeS3.new

    result = nil
    with_fake_s3(fake) do
      result = FieldPhotoStore.persist!(
        account_id: account.id, sha256: "a" * 64, binary: "bytes", content_type: "image/jpeg",
        filename: "photo.jpg", thumbnail_binary: "thumb", thumbnail_content_type: "image/jpeg",
        thumbnail_width: 88, thumbnail_height: 66
      )
    end

    assert result.persisted?
    assert_equal 1, fake.uploads.size
    assert_equal "field_photos/#{account.id}/#{'a' * 64}/original.jpg", fake.uploads.first[:key]
    assert_equal "field_photos/#{account.id}/#{'a' * 64}/original.jpg", result.s3_key_original
    assert_equal "thumb", result.thumbnail_data
  end

  test "a second call with the same account_id and sha256 does not re-upload" do
    account = make_account
    sha = "b" * 64
    fake = FakeS3.new

    first = second = nil
    with_fake_s3(fake) do
      first = FieldPhotoStore.persist!(account_id: account.id, sha256: sha, binary: "bytes",
                                        content_type: "image/jpeg", filename: "photo.jpg")
      second = FieldPhotoStore.persist!(account_id: account.id, sha256: sha, binary: "bytes",
                                         content_type: "image/jpeg", filename: "photo.jpg")
    end

    assert_equal first.id, second.id
    assert_equal 1, fake.uploads.size
  end

  test "returns nil and leaves no orphan row when upload_binary fails" do
    account = make_account
    fake = FakeS3.new(upload_succeeds: false)

    result = nil
    with_fake_s3(fake) do
      result = FieldPhotoStore.persist!(account_id: account.id, sha256: "c" * 64, binary: "bytes",
                                         content_type: "image/jpeg", filename: "photo.jpg")
    end

    assert_nil result
    assert_equal 0, FieldPhoto.where(account_id: account.id).count
  end

  test "RecordNotUnique resolves to the existing row instead of raising" do
    account = make_account
    sha = "d" * 64
    existing = FieldPhoto.create!(
      account_id: account.id, sha256: sha,
      s3_key_original: "field_photos/#{account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 10
    )

    orig_find_by = FieldPhoto.method(:find_by)
    seen = false
    FieldPhoto.define_singleton_method(:find_by) do |*args, **kwargs|
      if seen
        orig_find_by.call(*args, **kwargs)
      else
        seen = true
        nil
      end
    end

    fake = FakeS3.new
    result = nil
    with_fake_s3(fake) do
      result = FieldPhotoStore.persist!(account_id: account.id, sha256: sha, binary: "bytes",
                                         content_type: "image/jpeg", filename: "photo.jpg")
    end

    assert_equal existing.id, result.id
  ensure
    FieldPhoto.define_singleton_method(:find_by, orig_find_by)
  end

  test "fetch_binary returns nil without a stored key" do
    assert_nil FieldPhotoStore.fetch_binary(nil)
    assert_nil FieldPhotoStore.fetch_binary(FieldPhoto.new)
  end

  test "fetch_binary downloads the original from S3" do
    account = make_account
    photo = FieldPhoto.create!(
      account_id: account.id, sha256: "e" * 64,
      s3_key_original: "field_photos/#{account.id}/e/original.jpg",
      content_type: "image/jpeg", byte_size: 10
    )
    fake = FakeS3.new

    result = nil
    with_fake_s3(fake) { result = FieldPhotoStore.fetch_binary(photo) }

    assert_equal "original-bytes", result
    assert_equal [ photo.s3_key_original ], fake.downloads
  end
end
