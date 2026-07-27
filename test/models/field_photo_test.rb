# frozen_string_literal: true

require "test_helper"

class FieldPhotoTest < ActiveSupport::TestCase
  def build_account
    Account.create!(display_name: "Field Photo Co", slug: "field-photo-#{SecureRandom.hex(4)}")
  end

  def valid_attrs(account, overrides = {})
    {
      account: account,
      sha256: SecureRandom.hex(32),
      s3_key_original: "field_photos/#{account.id}/abc/original.jpg",
      content_type: "image/jpeg",
      byte_size: 12_345
    }.merge(overrides)
  end

  test "valid with required attributes" do
    account = build_account
    photo = FieldPhoto.new(valid_attrs(account))
    assert photo.valid?
  end

  test "requires sha256, s3_key_original, content_type, and byte_size" do
    account = build_account
    photo = FieldPhoto.new(account: account)
    assert_not photo.valid?
    assert photo.errors[:sha256].any?
    assert photo.errors[:s3_key_original].any?
    assert photo.errors[:content_type].any?
    assert photo.errors[:byte_size].any?
  end

  test "thumbnail_data_url returns nil without thumbnail bytes" do
    account = build_account
    photo = FieldPhoto.create!(valid_attrs(account))
    assert_nil photo.thumbnail_data_url
  end

  test "thumbnail_data_url returns a data URL when bytes are present" do
    account = build_account
    photo = FieldPhoto.create!(valid_attrs(account, thumbnail_data: "TESTBYTES", thumbnail_content_type: "image/jpeg"))
    expected = "data:image/jpeg;base64,#{Base64.strict_encode64('TESTBYTES')}"
    assert_equal expected, photo.thumbnail_data_url
  end

  test "unique index rejects a second row with the same account_id and sha256" do
    account = build_account
    sha = SecureRandom.hex(32)
    FieldPhoto.create!(valid_attrs(account, sha256: sha))

    assert_raises(ActiveRecord::RecordNotUnique) do
      FieldPhoto.connection.execute(<<~SQL.squish)
        INSERT INTO field_photos (account_id, sha256, s3_key_original, content_type, byte_size, created_at, updated_at)
        VALUES (#{account.id}, '#{sha}', 'field_photos/#{account.id}/dup/original.jpg', 'image/jpeg', 1, now(), now())
      SQL
    end
  end

  test "the same sha256 is allowed across different accounts" do
    account_a = build_account
    account_b = build_account
    sha = SecureRandom.hex(32)

    FieldPhoto.create!(valid_attrs(account_a, sha256: sha))
    photo_b = FieldPhoto.create!(valid_attrs(account_b, sha256: sha))

    assert photo_b.persisted?
  end
end
