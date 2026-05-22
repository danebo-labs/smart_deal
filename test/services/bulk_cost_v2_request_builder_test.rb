# frozen_string_literal: true

require "test_helper"

class BulkCostV2RequestBuilderTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  JPEG_BINARY = ("\xFF\xD8\xFF\xE0" + ("x" * 100)).b
  PDF_BINARY  = ("%PDF-1.4\n" + ("x" * 100)).b

  FakeAsset = Struct.new(:id, :custom_id, :sha256, :s3_key, :filename, :content_type, :office_origin, keyword_init: true)

  def fake_image_asset(content_type: "image/jpeg")
    FakeAsset.new(
      id:            1,
      custom_id:     "abc123",
      sha256:        "a" * 64,
      s3_key:        "bulk_uploads/photo.jpg",
      filename:      "photo.jpg",
      content_type:  content_type,
      office_origin: false
    )
  end

  def fake_pdf_asset(office_origin: false)
    FakeAsset.new(
      id:            2,
      custom_id:     "def456",
      sha256:        "b" * 64,
      s3_key:        "bulk_uploads/manual.pdf",
      filename:      "manual.pdf",
      content_type:  "application/pdf",
      office_origin: office_origin
    )
  end

  # Stub download so tests don't need S3
  def stub_download(builder, binary)
    builder.define_singleton_method(:download_binary_for) { |_asset| binary }
  end

  # ── Image → Sonnet path ───────────────────────────────────────────────────────

  test "image asset routes to Sonnet when gate decides :sonnet" do
    orig_decide = FieldPhotoDensityGate.method(:decide)
    FieldPhotoDensityGate.define_singleton_method(:decide) { |**| :sonnet }

    builder = BulkCostV2RequestBuilder.new
    stub_download(builder, JPEG_BINARY)

    asset          = fake_image_asset
    requests, meta = builder.build_all!([ asset ])

    assert_equal 1, requests.size
    assert_equal BatchChunkingPrompt::MODEL_TEXT, requests.first[:params][:model]
    assert_equal FieldPhotoPrompt::SYSTEM_BLOCKS,  requests.first[:params][:system]
    assert_equal [ asset.custom_id ],               meta[asset.id]
  ensure
    FieldPhotoDensityGate.define_singleton_method(:decide, orig_decide) if defined?(orig_decide)
  end

  test "image asset routes to Opus when gate decides :opus" do
    orig_decide = FieldPhotoDensityGate.method(:decide)
    FieldPhotoDensityGate.define_singleton_method(:decide) { |**| :opus }

    builder = BulkCostV2RequestBuilder.new
    stub_download(builder, JPEG_BINARY)

    asset          = fake_image_asset
    requests, meta = builder.build_all!([ asset ])

    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, requests.first[:params][:model]
    assert_equal BatchChunkingPrompt::SYSTEM_BLOCKS,    requests.first[:params][:system]
    assert_equal [ asset.custom_id ],                     meta[asset.id]
  ensure
    FieldPhotoDensityGate.define_singleton_method(:decide, orig_decide) if defined?(orig_decide)
  end

  # ── PDF → per-page path ───────────────────────────────────────────────────────

  test "PDF asset produces one request per kept page with _pN custom_ids" do
    orig_count = PdfPageSplitterService.instance_method(:page_count)
    orig_each  = PdfPageSplitterService.instance_method(:each_page)
    orig_cb    = PageRelevanceFilter.method(:call_batch)

    PdfPageSplitterService.define_method(:page_count) { 3 }
    PdfPageSplitterService.define_method(:each_page) do |&blk|
      [ 1, 2, 3 ].each { |n| blk.call(n, PDF_BINARY) }
    end
    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      pages.each_with_object({}) { |p, h| h[p.number] = { keep: true, reason: :test, source: :haiku_batch, force_opus: false } }
    end

    builder = BulkCostV2RequestBuilder.new
    stub_download(builder, PDF_BINARY)
    asset          = fake_pdf_asset
    requests, meta = builder.build_all!([ asset ])

    assert_equal 3, requests.size
    sha_prefix = asset.sha256[0, 16]
    assert_equal "#{sha_prefix}_p1", requests[0][:custom_id]
    assert_equal "#{sha_prefix}_p2", requests[1][:custom_id]
    assert_equal "#{sha_prefix}_p3", requests[2][:custom_id]
    assert_equal meta[asset.id], requests.pluck(:custom_id)
  ensure
    PdfPageSplitterService.define_method(:page_count, orig_count)
    PdfPageSplitterService.define_method(:each_page,  orig_each)
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
  end

  test "PDF drops filtered pages and force_opus uses Opus model" do
    orig_count = PdfPageSplitterService.instance_method(:page_count)
    orig_each  = PdfPageSplitterService.instance_method(:each_page)
    orig_cb    = PageRelevanceFilter.method(:call_batch)

    PdfPageSplitterService.define_method(:page_count) { 3 }
    PdfPageSplitterService.define_method(:each_page) do |&blk|
      [ 1, 2, 3 ].each { |n| blk.call(n, PDF_BINARY) }
    end
    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      {
        1 => { keep: false, reason: :cover, source: :haiku_batch, force_opus: false },
        2 => { keep: true,  reason: :text,  source: :haiku_batch, force_opus: false },
        3 => { keep: true,  reason: :scan,  source: :haiku_batch, force_opus: true  }
      }
    end

    builder = BulkCostV2RequestBuilder.new
    stub_download(builder, PDF_BINARY)
    asset           = fake_pdf_asset
    requests, _meta = builder.build_all!([ asset ])

    assert_equal 2, requests.size
    assert_equal BatchChunkingPrompt::MODEL_TEXT,       requests[0][:params][:model]
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, requests[1][:params][:model]
  ensure
    PdfPageSplitterService.define_method(:page_count, orig_count)
    PdfPageSplitterService.define_method(:each_page,  orig_each)
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
  end

  test "native PDF 2p without office_origin uses call_batch, p1 cover dropped" do
    orig_count = PdfPageSplitterService.instance_method(:page_count)
    orig_each  = PdfPageSplitterService.instance_method(:each_page)
    orig_cb    = PageRelevanceFilter.method(:call_batch)

    PdfPageSplitterService.define_method(:page_count) { 2 }
    PdfPageSplitterService.define_method(:each_page) do |&blk|
      [ 1, 2 ].each { |n| blk.call(n, PDF_BINARY) }
    end

    call_batch_called = false
    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      call_batch_called = true
      {
        1 => { keep: false, reason: :cover, source: :haiku_batch, force_opus: false },
        2 => { keep: true,  reason: :content, source: :haiku_batch, force_opus: false }
      }
    end

    builder = BulkCostV2RequestBuilder.new
    stub_download(builder, PDF_BINARY)
    asset           = fake_pdf_asset(office_origin: false)
    requests, _meta = builder.build_all!([ asset ])

    assert call_batch_called, "native PDF must use call_batch (not per-page)"
    assert_equal 1, requests.size, "only p2 kept after cover drop"
    assert_match(/_p2$/, requests.first[:custom_id])
  ensure
    PdfPageSplitterService.define_method(:page_count, orig_count)
    PdfPageSplitterService.define_method(:each_page,  orig_each)
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
  end

  # ── Legacy path (flag off) ────────────────────────────────────────────────────

  test "legacy build_requests uses Opus whole-file model" do
    asset = fake_image_asset

    # Access private method via service instance to confirm shape
    service = BatchIngestionService.new
    service.instance_variable_set(:@s3, OpenStruct.new(get_object: OpenStruct.new(body: StringIO.new(JPEG_BINARY))))
    service.instance_variable_set(:@bucket, "bucket")

    orig_download = service.method(:download_binary) rescue nil
    service.define_singleton_method(:download_binary) { |_key| JPEG_BINARY }

    reqs = service.send(:build_requests, [
      BulkUploadAsset.new(
        custom_id:    "test",
        sha256:       "a" * 64,
        s3_key:       "key",
        filename:     "f.jpg",
        content_type: "image/jpeg",
        status:       "uploaded_s3"
      )
    ])

    assert_equal BatchChunkingPrompt::MODEL, reqs.first[:params][:model]
  end
end
