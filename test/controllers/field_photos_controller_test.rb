# frozen_string_literal: true

require "test_helper"

class FieldPhotosControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @user.update!(account: @account)
    @photo = FieldPhoto.create!(
      account_id: @account.id, sha256: "a" * 64,
      s3_key_original: "field_photos/#{@account.id}/#{'a' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
  end

  def with_fake_url_service(url)
    original = FieldPhotoUrlService.instance_method(:call)
    FieldPhotoUrlService.define_method(:call) { |*_args| url }
    yield
  ensure
    FieldPhotoUrlService.define_method(:call, original)
  end

  test "redirects unauthenticated user to login" do
    get field_photo_path(@photo)
    assert_response :redirect
  end

  test "with session and own photo responds 302 to the S3 host" do
    sign_in @user

    with_fake_url_service("https://bucket.s3.amazonaws.com/field_photos/signed") do
      get field_photo_path(@photo)
      assert_response :redirect
      assert_match(%r{\Ahttps://bucket\.s3\.amazonaws\.com/}, @response.headers["Location"])
    end
  end

  test "a photo from another account responds 404" do
    sign_in @user
    other_photo = FieldPhoto.create!(
      account_id: accounts(:climb).id, sha256: "b" * 64,
      s3_key_original: "field_photos/#{accounts(:climb).id}/#{'b' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )

    get field_photo_path(other_photo)
    assert_response :not_found
  end

  test "an unknown id responds 404" do
    sign_in @user

    get field_photo_path(id: 999_999)
    assert_response :not_found
  end
end
