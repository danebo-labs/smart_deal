# frozen_string_literal: true

require "test_helper"

class InspectionFindingPhotoAttacherTest < ActiveSupport::TestCase
  class FakeS3
    attr_reader :uploads

    def initialize
      @uploads = []
    end

    def upload_binary(key, data, content_type)
      @uploads << { key: key, data: data, content_type: content_type }
      key
    end
  end

  def with_fake_s3(fake)
    orig = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { fake }
    yield
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
  end

  def upload(filename: "photo.png", content_type: "image/png")
    path = Rails.root.join("test/fixtures/files/tiny.png")
    ActionDispatch::Http::UploadedFile.new(
      tempfile: File.open(path, "rb"),
      filename: filename,
      type: content_type
    )
  end

  test "persists a FieldPhoto for the given account from an uploaded file" do
    account = accounts(:legacy)
    fake = FakeS3.new

    photo = nil
    with_fake_s3(fake) do
      photo = InspectionFindingPhotoAttacher.call(upload, account_id: account.id, user_id: users(:one).id)
    end

    assert photo.persisted?
    assert_equal account.id, photo.account_id
    assert_equal 1, fake.uploads.size
    assert photo.thumbnail_data.present?
  end

  test "returns nil without an uploaded file" do
    assert_nil InspectionFindingPhotoAttacher.call(nil, account_id: accounts(:legacy).id, user_id: users(:one).id)
  end

  test "reuses the existing photo on a repeat upload of the same bytes" do
    account = accounts(:legacy)
    fake = FakeS3.new

    first = second = nil
    with_fake_s3(fake) do
      first  = InspectionFindingPhotoAttacher.call(upload, account_id: account.id, user_id: users(:one).id)
      second = InspectionFindingPhotoAttacher.call(upload, account_id: account.id, user_id: users(:one).id)
    end

    assert_equal first.id, second.id
    assert_equal 1, fake.uploads.size
  end
end
