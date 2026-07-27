# frozen_string_literal: true

require "test_helper"

class FieldPhotoRetentionJobTest < ActiveSupport::TestCase
  class FakeS3
    attr_reader :prefixes

    def initialize(deleted_count: 1)
      @deleted_count = deleted_count
      @prefixes = []
    end

    def delete_prefix(prefix)
      @prefixes << prefix
      @deleted_count
    end
  end

  def with_fake_s3(fake)
    orig = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { fake }
    yield
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
  end

  def make_account
    Account.create!(display_name: "Retention Co", slug: "retention-#{SecureRandom.hex(4)}")
  end

  test "purges photos older than the retention window and keeps recent ones" do
    account = make_account
    expired = FieldPhoto.create!(
      account_id: account.id, sha256: "a" * 64,
      s3_key_original: "field_photos/#{account.id}/#{'a' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    expired.update!(created_at: 100.days.ago)
    recent = FieldPhoto.create!(
      account_id: account.id, sha256: "b" * 64,
      s3_key_original: "field_photos/#{account.id}/#{'b' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )

    fake = FakeS3.new
    with_fake_s3(fake) { FieldPhotoRetentionJob.perform_now }

    assert_not FieldPhoto.exists?(expired.id)
    assert FieldPhoto.exists?(recent.id)
  end

  test "calls delete_prefix with the correct account/sha prefix" do
    account = make_account
    photo = FieldPhoto.create!(
      account_id: account.id, sha256: "c" * 64,
      s3_key_original: "field_photos/#{account.id}/#{'c' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    photo.update!(created_at: 91.days.ago)

    fake = FakeS3.new
    with_fake_s3(fake) { FieldPhotoRetentionJob.perform_now }

    assert_equal [ "field_photos/#{account.id}/#{'c' * 64}/" ], fake.prefixes
  end

  test "respects FIELD_PHOTO_RETENTION_DAYS override" do
    account = make_account
    photo = FieldPhoto.create!(
      account_id: account.id, sha256: "d" * 64,
      s3_key_original: "field_photos/#{account.id}/#{'d' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    photo.update!(created_at: 10.days.ago)

    ENV["FIELD_PHOTO_RETENTION_DAYS"] = "5"
    fake = FakeS3.new
    with_fake_s3(fake) { FieldPhotoRetentionJob.perform_now }

    assert_not FieldPhoto.exists?(photo.id)
  ensure
    ENV.delete("FIELD_PHOTO_RETENTION_DAYS")
  end

  test "does not explode when S3 already lost the prefix (delete_prefix returns 0)" do
    account = make_account
    photo = FieldPhoto.create!(
      account_id: account.id, sha256: "e" * 64,
      s3_key_original: "field_photos/#{account.id}/#{'e' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    photo.update!(created_at: 100.days.ago)

    fake = FakeS3.new(deleted_count: 0)
    assert_nothing_raised do
      with_fake_s3(fake) { FieldPhotoRetentionJob.perform_now }
    end

    assert_not FieldPhoto.exists?(photo.id)
  end
end
