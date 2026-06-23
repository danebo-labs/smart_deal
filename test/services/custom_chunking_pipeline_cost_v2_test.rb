# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Tests for CustomChunkingPipeline routing: image/office → sync,
# short PDF (page_count ≤ SYNC_PAGES) → sync, long PDF → SubmitManualBatchJob.
class CustomChunkingPipelineCostV2Test < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @account = Account.create!(slug: "pipeline-test-#{SecureRandom.hex(4)}")
    @document_uid = SecureRandom.uuid
    @orig_s3_new  = S3DocumentsService.method(:new)
    @orig_sfc_new = SingleFileChunkingService.method(:new)
    @orig_bulk    = BulkKbSyncService.instance_method(:sync!)
    @orig_track   = TrackBedrockQueryJob.method(:perform_later)
    @orig_smb     = SubmitManualBatchJob.method(:perform_later)
    @orig_triage  = ProcessManualUrgentTriageJob.method(:perform_later)
    @orig_dedup   = ContentDedupService.method(:find_completed)
    @orig_splitter = PdfPageSplitterService.method(:new)

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:upload_file) do |_fn, _bin, _ct, account_id:, document_uid:|
      "uploads/#{account_id}/#{document_uid}/original.pdf"
    end
    fake_s3.define_singleton_method(:upload_text) { |key, _content| key }
    S3DocumentsService.define_singleton_method(:new) { |*| fake_s3 }

    BulkKbSyncService.define_method(:sync!) { |**| nil }
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    @dedup_calls = 0
    dedup_counter = -> { @dedup_calls += 1 }
    ContentDedupService.define_singleton_method(:find_completed) { |**| dedup_counter.call }

    @batch_job_calls = []
    batch_job_calls  = @batch_job_calls
    SubmitManualBatchJob.define_singleton_method(:perform_later) do |**kwargs|
      batch_job_calls << kwargs
    end

    @triage_job_calls = []
    triage_job_calls = @triage_job_calls
    ProcessManualUrgentTriageJob.define_singleton_method(:perform_later) do |**kwargs|
      triage_job_calls << kwargs
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
    ProcessManualUrgentTriageJob.define_singleton_method(:perform_later, @orig_triage)
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

  def pipeline(doc: pdf_doc, images: [], query: "", urgent: false)
    CustomChunkingPipeline.new(
      images: images,
      documents: doc ? [ doc ] : [],
      conv_session: nil,
      account_id: @account.id,
      document_uid: @document_uid,
      urgent: urgent,
      query: query
    )
  end

  # ── Routing tests ────────────────────────────────────────────────────────────

  test "single long PDF routes to SubmitManualBatchJob with account and document uid" do
    stub_pdf_page_count(CustomChunkingPipeline::SYNC_PAGES + 1)

    pipeline.run!

    assert_equal 1, @batch_job_calls.size, "expected SubmitManualBatchJob for long non-urgent PDF"
    assert_equal "manual.pdf", @batch_job_calls.first[:filename]
    assert_equal @account.id, @batch_job_calls.first[:account_id]
    assert_equal @document_uid, @batch_job_calls.first[:document_uid]
  end

  test "pilot bypasses dedup and urgent triage" do
    stub_pdf_page_count(10)

    pipeline(urgent: true, query: "Como hago rescate de emergencia?").run!

    assert_equal 1, @batch_job_calls.size
    assert_empty @triage_job_calls
    assert_equal 0, @dedup_calls
  end

  test "long PDF batch upload returns filename without immediate KB sync" do
    stub_pdf_page_count(CustomChunkingPipeline::SYNC_PAGES + 1)

    sync_calls = []
    BulkKbSyncService.define_method(:sync!) do |**kwargs|
      sync_calls << kwargs
      nil
    end

    result = pipeline(urgent: true).run!

    assert_equal [ "manual.pdf" ], result
    assert_equal 1, @batch_job_calls.size
    assert_empty sync_calls, "long manual must not sync the original PDF before batch chunks exist"
  end

  test "short PDF is outside pilot perimeter" do
    stub_pdf_page_count(CustomChunkingPipeline::SYNC_PAGES)

    assert_raises(CustomChunkingPipeline::PerimeterError) { pipeline.run! }

    assert_empty @batch_job_calls
  end

  test "Office file is outside pilot perimeter" do
    doc = { data: Base64.strict_encode64("docx"), media_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", filename: "manual.docx" }

    assert_raises(CustomChunkingPipeline::PerimeterError) { pipeline(doc: doc).run! }

    assert_empty @batch_job_calls
  end

  test "images are outside pilot perimeter" do
    image = { data: Base64.strict_encode64("img"), media_type: "image/jpeg", filename: "photo.jpg" }

    assert_raises(CustomChunkingPipeline::PerimeterError) { pipeline(doc: nil, images: [ image ]).run! }

    assert_empty @batch_job_calls
  end
end
