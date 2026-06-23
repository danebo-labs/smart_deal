# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Tests for CustomChunkingPipeline — pilot perimeter (account-scoped, PDF-only batch path).
class CustomChunkingPipelineTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @account = Account.create!(slug: "chunking-test-#{SecureRandom.hex(4)}")
    @document_uid = SecureRandom.uuid

    @orig_s3_new   = S3DocumentsService.method(:new)
    @orig_bulk     = BulkKbSyncService.instance_method(:sync!)
    @orig_track    = TrackBedrockQueryJob.method(:perform_later)
    @orig_pdf_new  = PdfPageSplitterService.method(:new)
    @orig_smb_later = SubmitManualBatchJob.method(:perform_later)

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:upload_file) do |fn, _bin, _ct, account_id: nil, document_uid: nil|
      if account_id && document_uid
        ext = File.extname(fn.to_s).delete_prefix(".").presence || "bin"
        "uploads/#{account_id}/#{document_uid}/original.#{ext}"
      else
        "uploads/#{fn}"
      end
    end
    fake_s3.define_singleton_method(:upload_text) { |key, _content| key }
    S3DocumentsService.define_singleton_method(:new) { |*| fake_s3 }

    BulkKbSyncService.define_method(:sync!) { |**| nil }
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }
    SubmitManualBatchJob.define_singleton_method(:perform_later) { |**| nil }
  end

  teardown do
    S3DocumentsService.define_singleton_method(:new, @orig_s3_new)
    BulkKbSyncService.define_method(:sync!, @orig_bulk)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, @orig_track)
    PdfPageSplitterService.define_singleton_method(:new, @orig_pdf_new)
    SubmitManualBatchJob.define_singleton_method(:perform_later, @orig_smb_later)
  end

  def stub_long_pdf
    fake_pdf = Object.new
    fake_pdf.define_singleton_method(:page_count) { 100 }
    PdfPageSplitterService.define_singleton_method(:new) { |_| fake_pdf }
  end

  def stub_short_pdf
    fake_pdf = Object.new
    fake_pdf.define_singleton_method(:page_count) { 1 }
    PdfPageSplitterService.define_singleton_method(:new) { |_| fake_pdf }
  end

  def long_pdf_doc(filename: "manual.pdf")
    { data: Base64.strict_encode64("%PDF bytes"), media_type: "application/pdf", filename: filename }
  end

  # ─── P-16: Pilot perimeter ───────────────────────────────────────────────────

  test "P-16: rejects image files — PerimeterError raised" do
    image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "photo.jpg" }
    pipeline = CustomChunkingPipeline.new(
      images: [ image ], documents: [], account_id: @account.id, document_uid: @document_uid
    )
    assert_raises(CustomChunkingPipeline::PerimeterError) { pipeline.run! }
  end

  test "P-16: rejects Office files — PerimeterError raised" do
    doc = { data: Base64.strict_encode64("docx bytes"), media_type: "application/pdf", filename: "manual.docx" }
    pipeline = CustomChunkingPipeline.new(
      images: [], documents: [ doc ], account_id: @account.id, document_uid: @document_uid
    )
    assert_raises(CustomChunkingPipeline::PerimeterError) { pipeline.run! }
  end

  test "P-16: rejects short PDF (≤ threshold pages) — PerimeterError raised" do
    stub_short_pdf
    pipeline = CustomChunkingPipeline.new(
      images: [], documents: [ long_pdf_doc ], account_id: @account.id, document_uid: @document_uid
    )
    assert_raises(CustomChunkingPipeline::PerimeterError) { pipeline.run! }
  end

  test "P-16: rejects multiple files — PerimeterError raised" do
    pipeline = CustomChunkingPipeline.new(
      images: [], documents: [ long_pdf_doc, long_pdf_doc(filename: "second.pdf") ],
      account_id: @account.id, document_uid: @document_uid
    )
    assert_raises(CustomChunkingPipeline::PerimeterError) { pipeline.run! }
  end

  test "P-16: rejects missing account_id — PerimeterError raised" do
    stub_long_pdf
    pipeline = CustomChunkingPipeline.new(
      images: [], documents: [ long_pdf_doc ], account_id: nil, document_uid: @document_uid
    )
    assert_raises(CustomChunkingPipeline::PerimeterError) { pipeline.run! }
  end

  test "P-16: rejects missing document_uid — PerimeterError raised" do
    stub_long_pdf
    pipeline = CustomChunkingPipeline.new(
      images: [], documents: [ long_pdf_doc ], account_id: @account.id, document_uid: nil
    )
    assert_raises(CustomChunkingPipeline::PerimeterError) { pipeline.run! }
  end

  test "P-16: ProcessManualUrgentTriageJob is never enqueued for any pilot perimeter case" do
    stub_long_pdf
    triage_calls = []
    orig = ProcessManualUrgentTriageJob.method(:perform_later)
    ProcessManualUrgentTriageJob.define_singleton_method(:perform_later) { |**kwargs| triage_calls << kwargs }

    # Long PDF passes perimeter — SubmitManualBatchJob enqueued, triage NEVER called
    CustomChunkingPipeline.new(
      images: [], documents: [ long_pdf_doc ], account_id: @account.id, document_uid: @document_uid
    ).run!

    # Image rejected — still no triage
    begin
      image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "photo.jpg" }
      CustomChunkingPipeline.new(
        images: [ image ], documents: [], account_id: @account.id, document_uid: @document_uid
      ).run!
    rescue CustomChunkingPipeline::PerimeterError
      nil
    end

    assert_empty triage_calls, "ProcessManualUrgentTriageJob must never be enqueued"
  ensure
    ProcessManualUrgentTriageJob.define_singleton_method(:perform_later, orig)
  end

  # ─── S3 key scoping (P-14) ───────────────────────────────────────────────────

  test "P-14: S3 key is scoped to account_id and document_uid" do
    stub_long_pdf
    uploaded_keys = []
    fake_s3 = Object.new
    fake_s3.define_singleton_method(:upload_file) do |fn, _bin, _ct, account_id: nil, document_uid: nil|
      ext = File.extname(fn.to_s).delete_prefix(".").presence || "bin"
      key = "uploads/#{account_id}/#{document_uid}/original.#{ext}"
      uploaded_keys << key
      key
    end
    S3DocumentsService.define_singleton_method(:new) { |*| fake_s3 }

    uid_a = SecureRandom.uuid
    uid_b = SecureRandom.uuid
    account_b = Account.create!(slug: "chunking-other-#{SecureRandom.hex(4)}")

    CustomChunkingPipeline.new(
      images: [], documents: [ long_pdf_doc ], account_id: @account.id, document_uid: uid_a
    ).run!
    CustomChunkingPipeline.new(
      images: [], documents: [ long_pdf_doc ], account_id: account_b.id, document_uid: uid_b
    ).run!

    assert_equal 2, uploaded_keys.uniq.size, "same filename for two accounts must produce different S3 keys"
    assert_includes uploaded_keys.first, @account.id.to_s
    assert_includes uploaded_keys.second, account_b.id.to_s
  end

  # ─── Long PDF happy path ─────────────────────────────────────────────────────

  test "long PDF passes perimeter and enqueues SubmitManualBatchJob" do
    stub_long_pdf
    enqueued = []
    orig = SubmitManualBatchJob.method(:perform_later)
    SubmitManualBatchJob.define_singleton_method(:perform_later) { |**kwargs| enqueued << kwargs }

    CustomChunkingPipeline.new(
      images: [], documents: [ long_pdf_doc ], account_id: @account.id, document_uid: @document_uid
    ).run!

    assert_equal 1, enqueued.size
    assert_equal @account.id, enqueued.first[:account_id]
    assert_equal @document_uid, enqueued.first[:document_uid]
  ensure
    SubmitManualBatchJob.define_singleton_method(:perform_later, orig)
  end
end
