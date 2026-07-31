# frozen_string_literal: true

require "test_helper"

class FieldPhotoUrlServiceTest < ActiveSupport::TestCase
  TEST_BUCKET = "test-bucket"

  class FakePresigner
    attr_reader :calls

    def initialize
      @calls = []
    end

    def presigned_url(operation, **opts)
      @calls << { operation: operation, opts: opts }
      "https://#{opts[:bucket]}.s3.amazonaws.com/#{opts[:key]}?X-Amz-Signature=fake"
    end
  end

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @fake = FakePresigner.new
    @account = accounts(:legacy)
    @svc = FieldPhotoUrlService.new(bucket: TEST_BUCKET, account: @account)
    @svc.instance_variable_set(:@presigner, @fake)
  end

  teardown do
    Rails.cache = @original_cache if @original_cache
  end

  test "returns nil when field_photo is nil" do
    assert_nil @svc.call(nil)
    assert_empty @fake.calls
  end

  test "returns nil for another account's photo without signing" do
    other_photo = FieldPhoto.create!(
      account_id: accounts(:climb).id, sha256: "c" * 64,
      s3_key_original: "field_photos/#{accounts(:climb).id}/#{'c' * 64}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )

    assert_nil @svc.call(other_photo)
    assert_empty @fake.calls
  end

  test "generates a presigned URL with inline disposition and 1h TTL" do
    photo = create_photo

    url = @svc.call(photo)

    assert_match(/X-Amz-Signature=/, url)
    assert_equal 1, @fake.calls.size
    opts = @fake.calls.first[:opts]
    assert_equal :get_object, @fake.calls.first[:operation]
    assert_equal TEST_BUCKET, opts[:bucket]
    assert_equal photo.s3_key_original, opts[:key]
    assert_equal FieldPhotoUrlService::URL_TTL_SECONDS, opts[:expires_in]
    assert_equal "inline", opts[:response_content_disposition]
    assert_match(/public, max-age=/, opts[:response_cache_control])
  end

  test "two calls within the same UTC hour return the same URL and hit the presigner once" do
    photo = create_photo

    travel_to Time.utc(2026, 5, 1, 12, 5, 0) do
      url1 = @svc.call(photo)
      url2 = @svc.call(photo)
      assert_equal url1, url2
      assert_equal 1, @fake.calls.size
    end
  end

  test "returns nil and logs when the presigner raises" do
    raising = Object.new
    def raising.presigned_url(*); raise StandardError, "AWS down"; end
    @svc.instance_variable_set(:@presigner, raising)

    assert_nil @svc.call(create_photo)
  end

  test "trusted_redirect_url? accepts virtual-hosted S3 hosts for the bucket" do
    assert @svc.trusted_redirect_url?("https://#{TEST_BUCKET}.s3.amazonaws.com/key?X-Amz-Signature=x")
    assert @svc.trusted_redirect_url?("https://#{TEST_BUCKET}.s3.us-east-1.amazonaws.com/key")
    assert @svc.trusted_redirect_url?("https://#{TEST_BUCKET}.s3-us-west-2.amazonaws.com/key")
    assert @svc.trusted_redirect_url?("https://#{TEST_BUCKET}.s3.dualstack.eu-west-1.amazonaws.com/key")
    assert @svc.trusted_redirect_url?("https://#{TEST_BUCKET}.s3-accelerate.amazonaws.com/key")
  end

  test "trusted_redirect_url? accepts path-style S3 URLs for the bucket" do
    assert @svc.trusted_redirect_url?("https://s3.amazonaws.com/#{TEST_BUCKET}/key")
    assert @svc.trusted_redirect_url?("https://s3.us-east-1.amazonaws.com/#{TEST_BUCKET}/key")
  end

  test "trusted_redirect_url? rejects non-HTTPS, foreign hosts, and credentialed URLs" do
    assert_not @svc.trusted_redirect_url?(nil)
    assert_not @svc.trusted_redirect_url?("")
    assert_not @svc.trusted_redirect_url?("http://#{TEST_BUCKET}.s3.amazonaws.com/key")
    assert_not @svc.trusted_redirect_url?("https://evil.example/#{TEST_BUCKET}/key")
    assert_not @svc.trusted_redirect_url?("https://other-bucket.s3.amazonaws.com/key")
    assert_not @svc.trusted_redirect_url?("https://s3.amazonaws.com/other-bucket/key")
    assert_not @svc.trusted_redirect_url?("https://user:pass@#{TEST_BUCKET}.s3.amazonaws.com/key")
    assert_not @svc.trusted_redirect_url?("not a url")
  end

  private

  def create_photo
    sha = SecureRandom.hex(32)
    FieldPhoto.create!(
      account_id: @account.id, sha256: sha,
      s3_key_original: "field_photos/#{@account.id}/#{sha}/original.jpg",
      content_type: "image/jpeg", byte_size: 4
    )
  end
end
