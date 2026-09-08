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

  # Records whether the row was still there when S3 was asked for the bytes.
  class RowProbeS3
    attr_reader :row_present

    def initialize
      @row_present = []
    end

    def delete_prefix(prefix)
      @row_present << FieldPhoto.exists?(sha256: prefix.split("/")[2])
      1
    end
  end

  # Creates the finding while the job already holds the batch, reproducing the
  # race the exclusion query cannot cover.
  class LinkingS3 < FakeS3
    def initialize(&linker)
      super()
      @linker = linker
      @linked = false
    end

    def delete_prefix(prefix)
      unless @linked
        @linked = true
        @linker.call
      end
      super
    end
  end

  def make_account
    Account.create!(display_name: "Retention Co", slug: "retention-#{SecureRandom.hex(4)}")
  end

  def expired_photo(account, seed)
    photo = FieldPhoto.create!(
      account_id: account.id, sha256: seed * 64,
      s3_key_original: "field_photos/#{account.id}/#{seed * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
    photo.update!(created_at: 100.days.ago)
    photo
  end

  def report_for(account)
    CertificationReport.create!(
      account: account, user: users(:one), building_name: "Edificio con evidencia"
    )
  end

  def prefix_of(photo)
    "field_photos/#{photo.account_id}/#{photo.sha256}/"
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

  # Fixed rule 10: a photo attached to a finding is report evidence, not cache.
  test "a photo linked to a finding survives the purge while an unlinked one is purged" do
    account  = make_account
    linked   = expired_photo(account, "1")
    unlinked = expired_photo(account, "2")
    InspectionFinding.create!(
      certification_report: report_for(account),
      body: "Puerta de piso sin enclavamiento.",
      field_photo: linked
    )

    fake = FakeS3.new
    summary = with_fake_s3(fake) { FieldPhotoRetentionJob.perform_now }

    assert FieldPhoto.exists?(linked.id), "evidence photo must survive the retention purge"
    assert_not FieldPhoto.exists?(unlinked.id)
    assert_equal [ prefix_of(unlinked) ], fake.prefixes, "evidence bytes must not be touched in S3"
    # aborted == 0 proves the exclusion query kept it, not the FK backstop.
    assert_equal({ purged: 1, kept: 1, aborted: 0 }, summary)
  end

  test "keeps evidence even when the finding was created long after the window closed" do
    account = make_account
    photo   = expired_photo(account, "3")
    InspectionFinding.create!(
      certification_report: report_for(account),
      body: "Foto tomada hace meses, hallazgo redactado hoy.",
      field_photo: photo
    )

    fake = FakeS3.new
    summary = with_fake_s3(fake) { FieldPhotoRetentionJob.perform_now }

    assert FieldPhoto.exists?(photo.id)
    assert_empty fake.prefixes
    assert_equal({ purged: 0, kept: 1, aborted: 0 }, summary)
  end

  # S3 deletes are irreversible; the row is not. Destroying the row first lets
  # the evidence FK abort the purge with the original still in the bucket.
  test "destroys the row before deleting the S3 bytes" do
    account = make_account
    expired_photo(account, "4")

    probe = RowProbeS3.new
    with_fake_s3(probe) { FieldPhotoRetentionJob.perform_now }

    assert_equal [ false ], probe.row_present
  end

  test "the evidence foreign key aborts a purge the exclusion query missed" do
    account = make_account
    first   = expired_photo(account, "5")
    second  = expired_photo(account, "6")
    report  = report_for(account)

    linker = LinkingS3.new do
      InspectionFinding.create!(
        certification_report: report, body: "Hallazgo dictado durante la purga.", field_photo: second
      )
    end
    summary = nil
    assert_nothing_raised { with_fake_s3(linker) { summary = FieldPhotoRetentionJob.perform_now } }

    assert_not FieldPhoto.exists?(first.id)
    assert FieldPhoto.exists?(second.id), "the FK must abort the delete instead of losing the bytes"
    assert_equal [ prefix_of(first) ], linker.prefixes
    assert_equal({ purged: 1, kept: 0, aborted: 1 }, summary)
  end
end
