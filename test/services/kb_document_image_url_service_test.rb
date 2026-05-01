# frozen_string_literal: true

require 'test_helper'

class KbDocumentImageUrlServiceTest < ActiveSupport::TestCase
  TEST_BUCKET = 'test-bucket'

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
    @fake = FakePresigner.new
    @svc  = KbDocumentImageUrlService.new(bucket: TEST_BUCKET)
    @svc.instance_variable_set(:@presigner, @fake)
  end

  test "returns nil for non-image extensions" do
    pdf = KbDocument.create!(s3_key: 'uploads/2026-04-30/manual.pdf', display_name: 'PDF', aliases: [])
    assert_nil @svc.call(pdf)
    assert_empty @fake.calls
  end

  test "returns nil for blank s3_key" do
    doc = KbDocument.new(s3_key: '')
    assert_nil @svc.call(doc)
  end

  test "returns nil when kb_document is nil" do
    assert_nil @svc.call(nil)
  end

  test "generates presigned URL for image extensions" do
    %w[.png .jpg .jpeg .gif .webp].each do |ext|
      doc = KbDocument.create!(s3_key: "uploads/2026-04-30/photo#{ext}", display_name: "img#{ext}", aliases: [])
      url = @svc.call(doc)
      assert_match(/X-Amz-Signature=/, url, "expected signed URL for #{ext}")
    end
  end

  test "passes inline disposition and 1h TTL to presigner" do
    doc = KbDocument.create!(s3_key: 'uploads/2026-04-30/p.jpg', display_name: 'p', aliases: [])
    @svc.call(doc)

    assert_equal 1, @fake.calls.size
    call = @fake.calls.first
    opts = call[:opts]
    assert_equal :get_object,                                    call[:operation]
    assert_equal TEST_BUCKET,                                    opts[:bucket]
    assert_equal 'uploads/2026-04-30/p.jpg',                     opts[:key]
    assert_equal KbDocumentImageUrlService::URL_TTL_SECONDS,     opts[:expires_in]
    assert_equal 'inline',                                       opts[:response_content_disposition]
    assert_match(/public, max-age=/,                             opts[:response_cache_control])
  end

  test "strips s3:// prefix from s3_key" do
    doc = KbDocument.create!(s3_key: 's3://other-bucket/uploads/2026-04-30/p.jpg', display_name: 'p', aliases: [])
    @svc.call(doc)
    assert_equal 'uploads/2026-04-30/p.jpg', @fake.calls.first[:opts][:key]
    assert_equal TEST_BUCKET,                @fake.calls.first[:opts][:bucket]
  end

  test "returns nil and logs when presigner raises" do
    raising = Object.new
    def raising.presigned_url(*); raise StandardError, 'AWS down'; end
    @svc.instance_variable_set(:@presigner, raising)

    doc = KbDocument.create!(s3_key: 'uploads/2026-04-30/p.jpg', display_name: 'p', aliases: [])
    assert_nil @svc.call(doc)
  end

  test "call_many returns a Hash keyed by document" do
    img = KbDocument.create!(s3_key: 'uploads/2026-04-30/p.jpg', display_name: 'i', aliases: [])
    pdf = KbDocument.create!(s3_key: 'uploads/2026-04-30/d.pdf', display_name: 'd', aliases: [])
    map = @svc.call_many([ img, pdf ])
    assert_match(/X-Amz-Signature=/, map[img])
    assert_nil map[pdf]
  end
end
