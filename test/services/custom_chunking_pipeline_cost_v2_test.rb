# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Tests for CustomChunkingPipeline routing: image/office → sync,
# short PDF (page_count ≤ SYNC_PAGES) → sync, long PDF → SubmitManualBatchJob.
class CustomChunkingPipelineCostV2Test < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @orig_s3_new  = S3DocumentsService.method(:new)
    @orig_sfc_new = SingleFileChunkingService.method(:new)
    @orig_bulk    = BulkKbSyncService.instance_method(:sync!)
    @orig_track   = TrackBedrockQueryJob.method(:perform_later)
    @orig_smb     = SubmitManualBatchJob.method(:perform_later)
    @orig_dedup   = ContentDedupService.method(:find_completed)
    @orig_splitter = PdfPageSplitterService.method(:new)

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:upload_file) { |fn, _bin, _ct| "uploads/#{fn}" }
    fake_s3.define_singleton_method(:upload_text) { |key, _content| key }
    S3DocumentsService.define_singleton_method(:new) { |*| fake_s3 }

    BulkKbSyncService.define_method(:sync!) { |**| nil }
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    ContentDedupService.define_singleton_method(:find_completed) do |sha256:, contract_version:|
      ContentDedupService::Result.new(hit: false, asset: nil, canonical_name: nil, aliases: [])
    end

    @batch_job_calls = []
    batch_job_calls  = @batch_job_calls
    SubmitManualBatchJob.define_singleton_method(:perform_later) do |**kwargs|
      batch_job_calls << kwargs
    end

    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      asset = ChunkAsset.new(
        filename: kwargs[:filename], sha256: "abc",
        s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type]
      )
      asset.canonical_name = "Test Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end
  end

  teardown do
    S3DocumentsService.define_singleton_method(:new, @orig_s3_new)
    SingleFileChunkingService.define_singleton_method(:new, @orig_sfc_new)
    BulkKbSyncService.define_method(:sync!, @orig_bulk)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, @orig_track)
    SubmitManualBatchJob.define_singleton_method(:perform_later, @orig_smb)
    ContentDedupService.define_singleton_method(:find_completed, @orig_dedup)
    PdfPageSplitterService.define_singleton_method(:new, @orig_splitter)
  end

  def stub_pdf_page_count(count)
    fake = Object.new
    fake.define_singleton_method(:page_count) { count }
    PdfPageSplitterService.define_singleton_method(:new) { |_binary| fake }
  end

  def pdf_doc(filename: "manual.pdf")
    { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: filename }
  end

  # ── Routing tests ────────────────────────────────────────────────────────────

  test "PDF non-urgent, page_count > SYNC_PAGES → SubmitManualBatchJob (async Batch)" do
    stub_pdf_page_count(CustomChunkingPipeline::SYNC_PAGES + 1)

    CustomChunkingPipeline.new(images: [], documents: [ pdf_doc ], conv_session: nil, urgent: false).run!

    assert_equal 1, @batch_job_calls.size, "expected SubmitManualBatchJob for long non-urgent PDF"
    assert_equal "manual.pdf", @batch_job_calls.first[:filename]
  end

  test "PDF urgent flag true still routes long manuals to batch" do
    stub_pdf_page_count(10)

    sfc_calls = 0
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      sfc_calls += 1
      asset = ChunkAsset.new(filename: kwargs[:filename], sha256: "abc",
                              s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type])
      asset.canonical_name = "Test Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end

    CustomChunkingPipeline.new(images: [], documents: [ pdf_doc ], conv_session: nil, urgent: true).run!

    assert_equal 1, @batch_job_calls.size, "long PDF must go to batch even when caller passes urgent"
    assert_equal 0, sfc_calls, "long PDF must not use sync SingleFileChunkingService"
  end

  test "long PDF batch upload returns filename without immediate KB sync" do
    stub_pdf_page_count(CustomChunkingPipeline::SYNC_PAGES + 1)

    sync_calls = []
    BulkKbSyncService.define_method(:sync!) do |**kwargs|
      sync_calls << kwargs
      nil
    end

    result = CustomChunkingPipeline.new(images: [], documents: [ pdf_doc ], conv_session: nil, urgent: true).run!

    assert_equal [ "manual.pdf" ], result
    assert_equal 1, @batch_job_calls.size
    assert_empty sync_calls, "long manual must not sync the original PDF before batch chunks exist"
  end

  test "PDF non-urgent, page_count <= SYNC_PAGES → sync" do
    stub_pdf_page_count(CustomChunkingPipeline::SYNC_PAGES)

    sfc_calls = 0
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      sfc_calls += 1
      asset = ChunkAsset.new(filename: kwargs[:filename], sha256: "abc",
                              s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type])
      asset.canonical_name = "Test Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end

    CustomChunkingPipeline.new(images: [], documents: [ pdf_doc ], conv_session: nil, urgent: false).run!

    assert_equal 0, @batch_job_calls.size, "short PDF must NOT go to batch"
    assert_equal 1, sfc_calls, "short PDF must use SingleFileChunkingService"
  end

  test "Office file (.docx) always routes to sync regardless of urgent" do
    sfc_calls = 0
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      sfc_calls += 1
      asset = ChunkAsset.new(filename: kwargs[:filename], sha256: "abc",
                              s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type])
      asset.canonical_name = "Test Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end

    doc = { data: Base64.strict_encode64("docx"), media_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", filename: "manual.docx" }
    CustomChunkingPipeline.new(images: [], documents: [ doc ], conv_session: nil, urgent: false).run!

    assert_equal 0, @batch_job_calls.size, "Office docs must NOT go to batch"
    assert_equal 1, sfc_calls, "Office docs must always use SingleFileChunkingService"
  end

  test "images always route to sync" do
    sfc_calls = 0
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      sfc_calls += 1
      asset = ChunkAsset.new(filename: kwargs[:filename], sha256: "ghi",
                              s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type])
      asset.canonical_name = "Photo Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end

    image = { data: Base64.strict_encode64("img"), media_type: "image/jpeg", filename: "photo.jpg" }
    CustomChunkingPipeline.new(images: [ image ], documents: [], conv_session: nil).run!

    assert_equal 0, @batch_job_calls.size, "images must NOT go through batch"
    assert_equal 1, sfc_calls, "images must always use SingleFileChunkingService"
  end
end
