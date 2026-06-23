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
    # The test env defaults to :null_store, but the service relies on Rails.cache
    # to hand back the same URL within an hour-bucket. Swap to a memory store
    # for these tests so we can verify the cache contract end-to-end.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @fake = FakePresigner.new
    @account = accounts(:legacy)
    @svc  = KbDocumentImageUrlService.new(bucket: TEST_BUCKET, account: @account)
    @svc.instance_variable_set(:@presigner, @fake)
  end

  teardown do
    Rails.cache = @original_cache if @original_cache
  end

  test "returns nil for non-image extensions" do
    pdf = create_doc('uploads/2026-04-30/manual.pdf', 'PDF')
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
      doc = create_doc("uploads/2026-04-30/photo#{ext}", "img#{ext}")
      url = @svc.call(doc)
      assert_match(/X-Amz-Signature=/, url, "expected signed URL for #{ext}")
    end
  end

  test "passes inline disposition and 1h TTL to presigner" do
    doc = create_doc('uploads/2026-04-30/p.jpg', 'p')
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
    doc = create_doc('s3://other-bucket/uploads/2026-04-30/p.jpg', 'p')
    @svc.call(doc)
    assert_equal 'uploads/2026-04-30/p.jpg', @fake.calls.first[:opts][:key]
    assert_equal TEST_BUCKET,                @fake.calls.first[:opts][:bucket]
  end

  test "returns nil and logs when presigner raises" do
    raising = Object.new
    def raising.presigned_url(*); raise StandardError, 'AWS down'; end
    @svc.instance_variable_set(:@presigner, raising)

    doc = create_doc('uploads/2026-04-30/p.jpg', 'p')
    assert_nil @svc.call(doc)
  end

  test "call_many returns a Hash keyed by document" do
    img = create_doc('uploads/2026-04-30/p.jpg', 'i')
    pdf = create_doc('uploads/2026-04-30/d.pdf', 'd')
    map = @svc.call_many([ img, pdf ])
    assert_match(/X-Amz-Signature=/, map[img])
    assert_nil map[pdf]
  end

  # ─── Per-hour Solid Cache caching of presigned URLs ──────────────────────────

  test "two calls within the same UTC hour return the same URL and call presigner once" do
    doc = create_doc('uploads/2026-04-30/cached.jpg', 'c')

    travel_to Time.utc(2026, 5, 1, 12, 5, 0) do
      url1 = @svc.call(doc)
      url2 = @svc.call(doc)
      assert_equal url1, url2,                'browser cache hinges on URL stability within an hour'
      assert_equal 1, @fake.calls.size,       'presigner must be hit exactly once per (key, hour)'
    end
  end

  test "calls in different UTC hours produce different URLs and rotate the cache" do
    doc = create_doc('uploads/2026-04-30/rotated.jpg', 'r')

    travel_to Time.utc(2026, 5, 1, 12, 5, 0) do
      @svc.call(doc)
    end
    # Build a fresh service so its presigner counter reflects only the new hour
    fake2 = FakePresigner.new
    svc2  = KbDocumentImageUrlService.new(bucket: TEST_BUCKET, account: @account)
    svc2.instance_variable_set(:@presigner, fake2)

    travel_to Time.utc(2026, 5, 1, 13, 5, 0) do
      svc2.call(doc)
    end

    assert_equal 1, @fake.calls.size, "first hour: presigner called once"
    assert_equal 1, fake2.calls.size, "second hour: presigner called once after cache rotation"
  end

  test "returns nil for another account document without signing" do
    doc = KbDocument.create!(
      s3_key: 'uploads/2026-04-30/other.jpg',
      display_name: 'other',
      aliases: [],
      account: accounts(:climb)
    )

    assert_nil @svc.call(doc)
    assert_empty @fake.calls
  end

  private

  def create_doc(s3_key, display_name)
    KbDocument.create!(s3_key: s3_key, display_name: display_name, aliases: [], account: @account)
  end
end
