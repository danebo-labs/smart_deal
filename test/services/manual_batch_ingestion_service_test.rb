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
    # Stub PageRelevanceFilter to keep all pages
    orig_prf = PageRelevanceFilter.instance_method(:call)
    PageRelevanceFilter.define_method(:call) { { keep: true, reason: :test, source: :heuristic } }

    # Stub TrackBedrockQueryJob
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    fake_client = FakeBatchClient.new
    pdf_binary  = build_fake_pdf_binary(3)

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
    PageRelevanceFilter.define_method(:call, orig_prf)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end

  test "all submitted requests use MODEL_TEXT (Sonnet) by default" do
    orig_prf = PageRelevanceFilter.instance_method(:call)
    PageRelevanceFilter.define_method(:call) { { keep: true, reason: :test, source: :heuristic } }
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    fake_client = FakeBatchClient.new
    pdf_binary  = build_fake_pdf_binary(2)

    ManualBatchIngestionService.new(batch_client: fake_client).submit!(
      binary: pdf_binary, filename: "m.pdf", sha256: "c" * 64, s3_key: "key"
    )

    models = fake_client.submitted_requests.map { |r| r[:params][:model] }
    assert models.all? { |m| m == BatchChunkingPrompt::MODEL_TEXT },
           "expected Sonnet for all requests, got: #{models.inspect}"
  ensure
    PageRelevanceFilter.define_method(:call, orig_prf)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end

  test "force_opus pages use MODEL_MULTIMODAL" do
    call_count = 0
    orig_prf   = PageRelevanceFilter.instance_method(:call)
    PageRelevanceFilter.define_method(:call) do
      call_count += 1
      # First page: force_opus; others: normal
      if instance_variable_get(:@page_number) == 1
        { keep: true, reason: :scanned_image, source: :heuristic, force_opus: true }
      else
        { keep: true, reason: :test, source: :heuristic }
      end
    end
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

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
    PageRelevanceFilter.define_method(:call, orig_prf)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end

  test "page_customs maps page numbers to stable custom_ids" do
    orig_prf = PageRelevanceFilter.instance_method(:call)
    PageRelevanceFilter.define_method(:call) { { keep: true, reason: :test, source: :heuristic } }
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

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
    PageRelevanceFilter.define_method(:call, orig_prf)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end

  test "dropped pages are excluded from batch requests" do
    orig_prf = PageRelevanceFilter.instance_method(:call)
    PageRelevanceFilter.define_method(:call) do
      # Drop page 1 (title/boilerplate heuristic)
      keep = instance_variable_get(:@page_number) != 1
      { keep: keep, reason: keep ? :content : :title_page, source: :heuristic }
    end
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    fake_client = FakeBatchClient.new
    pdf_binary  = build_fake_pdf_binary(3)

    result = ManualBatchIngestionService.new(batch_client: fake_client).submit!(
      binary: pdf_binary, filename: "m.pdf", sha256: "f" * 64, s3_key: "key"
    )

    assert_equal 2, fake_client.submitted_requests.size, "only pages 2+3 should be submitted"
    assert_equal [ 2, 3 ], result[:kept_pages].sort
  ensure
    PageRelevanceFilter.define_method(:call, orig_prf)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
  end
end
