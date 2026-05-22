# frozen_string_literal: true

require "test_helper"

class ManualBatchIngestionServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ── Fakes ────────────────────────────────────────────────────────────────────

  class FakeBatchClient
    attr_reader :submitted_requests

    def initialize
      @submitted_requests = []
      @batch_id_counter   = 0
    end

    def submit_batch(requests:)
      @submitted_requests.concat(requests)
      @batch_id_counter += 1
      OpenStruct.new(id: "msgbatch_test_#{@batch_id_counter}")
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  # Builds a minimal multi-page PDF using HexaPDF (already in Gemfile)
  def build_fake_pdf_binary(page_count)
    doc = HexaPDF::Document.new
    page_count.times { |i| doc.pages.add.canvas.move_to(0, 0).line_to(100, 100).stroke }
    io = StringIO.new("".b)
    doc.write(io, validate: false)
    io.string
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

  test "returns empty result for zero-page PDF" do
    orig_count = PdfPageSplitterService.instance_method(:page_count)
    PdfPageSplitterService.define_method(:page_count) { 0 }

    result = ManualBatchIngestionService.new(batch_client: FakeBatchClient.new).submit!(
      binary: "%PDF stub", filename: "empty.pdf", sha256: "a" * 64, s3_key: "key"
    )

    assert_equal({}, result[:page_customs])
    assert_equal [], result[:kept_pages]
    assert_nil result[:batch_id]
  ensure
    PdfPageSplitterService.define_method(:page_count, orig_count)
  end

  test "submits N batch requests = pages kept after filter" do
    orig_cb    = PageRelevanceFilter.method(:call_batch)
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    fake_client = FakeBatchClient.new
    pdf_binary  = build_fake_pdf_binary(3)

    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      pages.each_with_object({}) { |p, h| h[p.number] = { keep: true, reason: :test, source: :haiku_batch, force_opus: false } }
    end

    result = ManualBatchIngestionService.new(batch_client: fake_client).submit!(
      binary:   pdf_binary,
      filename: "manual_3p.pdf",
      sha256:   "b" * 64,
      s3_key:   "uploads/manual_3p.pdf"
    )

    assert_equal 3, fake_client.submitted_requests.size, "expected 3 batch requests for 3 pages"
    assert_equal 3, result[:kept_pages].size
    assert result[:batch_id].present?
  ensure
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end

  test "all submitted requests use MODEL_TEXT (Sonnet) by default" do
    orig_cb    = PageRelevanceFilter.method(:call_batch)
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      pages.each_with_object({}) { |p, h| h[p.number] = { keep: true, reason: :test, source: :haiku_batch, force_opus: false } }
    end

    fake_client = FakeBatchClient.new
    pdf_binary  = build_fake_pdf_binary(2)

    ManualBatchIngestionService.new(batch_client: fake_client).submit!(
      binary: pdf_binary, filename: "m.pdf", sha256: "c" * 64, s3_key: "key"
    )

    models = fake_client.submitted_requests.map { |r| r[:params][:model] }
    assert models.all? { |m| m == BatchChunkingPrompt::MODEL_TEXT },
           "expected Sonnet for all requests, got: #{models.inspect}"
  ensure
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end

  test "force_opus pages use MODEL_MULTIMODAL" do
    orig_cb    = PageRelevanceFilter.method(:call_batch)
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      {
        pages.first.number => { keep: true, reason: :scanned_image, source: :haiku_batch, force_opus: true },
        pages.last.number  => { keep: true, reason: :test,          source: :haiku_batch, force_opus: false }
      }
    end

    fake_client = FakeBatchClient.new
    pdf_binary  = build_fake_pdf_binary(2)

    ManualBatchIngestionService.new(batch_client: fake_client).submit!(
      binary: pdf_binary, filename: "m.pdf", sha256: "d" * 64, s3_key: "key"
    )

    models = fake_client.submitted_requests.map { |r| r[:params][:model] }
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, models.first,
                 "p1 (force_opus) should use Opus"
    assert_equal BatchChunkingPrompt::MODEL_TEXT, models.last,
                 "p2 (normal) should use Sonnet"
  ensure
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end

  test "page_customs maps page numbers to stable custom_ids" do
    orig_cb    = PageRelevanceFilter.method(:call_batch)
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      pages.each_with_object({}) { |p, h| h[p.number] = { keep: true, reason: :test, source: :haiku_batch, force_opus: false } }
    end

    sha256     = "e" * 64
    pdf_binary = build_fake_pdf_binary(2)
    result     = ManualBatchIngestionService.new(batch_client: FakeBatchClient.new).submit!(
      binary: pdf_binary, filename: "m.pdf", sha256: sha256, s3_key: "key"
    )

    assert_equal 2, result[:page_customs].size
    result[:page_customs].each do |page_num, custom_id|
      assert custom_id.include?(sha256[0..15]), "custom_id should embed sha256 prefix"
      assert custom_id.include?("_p#{page_num}"), "custom_id should embed page number"
    end
  ensure
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end

  test "dropped pages are excluded from batch requests" do
    orig_cb    = PageRelevanceFilter.method(:call_batch)
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      pages.each_with_object({}) do |p, h|
        keep = p.number != 1
        h[p.number] = { keep: keep, reason: keep ? :content : :cover, source: :haiku_batch, force_opus: false }
      end
    end

    fake_client = FakeBatchClient.new
    pdf_binary  = build_fake_pdf_binary(3)

    result = ManualBatchIngestionService.new(batch_client: fake_client).submit!(
      binary: pdf_binary, filename: "m.pdf", sha256: "f" * 64, s3_key: "key"
    )

    assert_equal 2, fake_client.submitted_requests.size, "only pages 2+3 should be submitted"
    assert_equal [ 2, 3 ], result[:kept_pages].sort
  ensure
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end

  test "native PDF 2p: p1 dropped via batch → 1 batch request submitted" do
    orig_cb    = PageRelevanceFilter.method(:call_batch)
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    call_batch_received_pages = nil
    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      call_batch_received_pages = pages.map(&:number)
      {
        1 => { keep: false, reason: :cover, source: :haiku_batch, force_opus: false },
        2 => { keep: true,  reason: :content, source: :haiku_batch, force_opus: false }
      }
    end

    fake_client = FakeBatchClient.new
    pdf_binary  = build_fake_pdf_binary(2)

    result = ManualBatchIngestionService.new(batch_client: fake_client).submit!(
      binary: pdf_binary, filename: "manual.pdf", sha256: "0" * 64, s3_key: "key"
    )

    assert_equal [ 1, 2 ], call_batch_received_pages, "call_batch must receive both pages"
    assert_equal 1, fake_client.submitted_requests.size, "only p2 kept"
    assert_equal [ 2 ], result[:kept_pages]
  ensure
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end
end
