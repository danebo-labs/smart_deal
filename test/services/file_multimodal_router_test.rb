# frozen_string_literal: true

require "test_helper"

class FileMultimodalRouterTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Fakes — avoids real HexaPDF / PDF::Reader calls in unit tests
  # ---------------------------------------------------------------------------

  setup do
    # PdfImageDetector — thread-local so parallel-safe
    @orig_image_pages = PdfImageDetector.method(:image_pages)
    @orig_has_images  = PdfImageDetector.method(:has_images?)
    Thread.current[:pdf_image_pages] = Set.new
    PdfImageDetector.define_singleton_method(:image_pages) { |_| Thread.current[:pdf_image_pages] }
    PdfImageDetector.define_singleton_method(:has_images?) { |_| Thread.current[:pdf_image_pages]&.any? }

    # PdfPageSplitterService.page_count — default 1 (single-page) so existing text-only tests pass
    @orig_page_count = PdfPageSplitterService.instance_method(:page_count)
    PdfPageSplitterService.define_method(:page_count) { 1 }

    # PageImageDensityAnalyzer — default: no images, pure text
    @orig_analyzer = PageImageDensityAnalyzer.method(:analyze)
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: false, text_layer_chars: 0, image_area_ratio: 0.0 }
    end
  end

  teardown do
    PdfImageDetector.define_singleton_method(:image_pages, @orig_image_pages)
    PdfImageDetector.define_singleton_method(:has_images?,  @orig_has_images)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  # ---------------------------------------------------------------------------
  # Text MIME types → :text mode, Sonnet
  # ---------------------------------------------------------------------------

  test "classifies text/plain as text mode with MODEL_TEXT" do
    r = FileMultimodalRouter.classify(binary: "hello", content_type: "text/plain", filename: "note.txt")
    assert_equal :text,                              r.mode
    assert_equal BatchChunkingPrompt::MODEL_TEXT,    r.model
    assert_empty r.pages
  end

  test "classifies text/markdown as text mode" do
    r = FileMultimodalRouter.classify(binary: "# h", content_type: "text/markdown", filename: "readme.md")
    assert_equal :text, r.mode
  end

  test "classifies text/csv as text mode" do
    r = FileMultimodalRouter.classify(binary: "a,b", content_type: "text/csv", filename: "data.csv")
    assert_equal :text, r.mode
  end

  # ---------------------------------------------------------------------------
  # Image MIME types → :image mode, Sonnet (cost_v2: was Opus, downgraded 2026-05-21)
  # FieldPhotoDensityGate may upgrade to Opus at parse time; router default is Sonnet.
  # ---------------------------------------------------------------------------

  test "classifies image/jpeg as image mode with MODEL_TEXT" do
    r = FileMultimodalRouter.classify(binary: "\xFF\xD8", content_type: "image/jpeg", filename: "photo.jpg")
    assert_equal :image,                             r.mode
    assert_equal BatchChunkingPrompt::MODEL_TEXT,    r.model
  end

  test "classifies image/png as image mode" do
    r = FileMultimodalRouter.classify(binary: "\x89PNG", content_type: "image/png", filename: "img.png")
    assert_equal :image, r.mode
  end

  # ---------------------------------------------------------------------------
  # PDF without images → :pdf_text_only
  # ---------------------------------------------------------------------------

  test "classifies single-page PDF as pdf_text_only regardless of XObjects" do
    # page_count=1 (setup default) → pdf_text_only; image_pages irrelevant
    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "doc.pdf")
    assert_equal :pdf_text_only,                   r.mode
    assert_equal BatchChunkingPrompt::MODEL_TEXT,  r.model
    assert_empty r.pages
  end

  # ---------------------------------------------------------------------------
  # PDF with images → :pdf_mixed (splitter stubbed)
  # ---------------------------------------------------------------------------

  test "classifies multi-page PDF with images as pdf_mixed" do
    Thread.current[:pdf_image_pages] = Set.new([ 1 ])
    orig_each_page = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 2 }
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake_page_binary") }

    r = FileMultimodalRouter.classify(binary: "%PDF-mixed", content_type: "application/pdf", filename: "mixed.pdf")
    assert_equal :pdf_mixed, r.mode
    assert_equal 1,          r.pages.count
    assert_equal 1,          r.pages.first.number
  ensure
    PdfPageSplitterService.define_method(:each_page, orig_each_page)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
  end

  # ---------------------------------------------------------------------------
  # Office extensions → :office
  # ---------------------------------------------------------------------------

  test "classifies .docx extension as office mode" do
    r = FileMultimodalRouter.classify(binary: "PK...", content_type: "application/octet-stream", filename: "report.docx")
    assert_equal :office, r.mode
  end

  test "classifies .xlsx extension as office mode" do
    r = FileMultimodalRouter.classify(binary: "PK...", content_type: "application/octet-stream", filename: "data.xlsx")
    assert_equal :office, r.mode
  end

  test "classifies .pptx extension as office mode" do
    r = FileMultimodalRouter.classify(binary: "PK...", content_type: "application/octet-stream", filename: "deck.pptx")
    assert_equal :office, r.mode
  end

  test "classifies .ppt extension as office mode" do
    r = FileMultimodalRouter.classify(binary: "D0CF", content_type: "application/octet-stream", filename: "legacy.ppt")
    assert_equal :office, r.mode
  end

  test "classifies application/msword MIME as office regardless of extension" do
    r = FileMultimodalRouter.classify(binary: "D0CF", content_type: "application/msword", filename: "legacy.doc")
    assert_equal :office, r.mode
  end

  # ---------------------------------------------------------------------------
  # route_page model selection: Sonnet default, Opus only for scanned_dense
  # (cost-v2 ADR: text_layer_chars < 100 AND image_area_ratio > 0.7 → Opus)
  # ---------------------------------------------------------------------------

  test "page with has_images and text_chars>500, image_ratio<0.20 routes to MODEL_TEXT (downgrade)" do
    Thread.current[:pdf_image_pages] = Set.new([ 1 ])
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 2 }
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: true, text_layer_chars: 800, image_area_ratio: 0.10 }
    end
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "doc.pdf")
    assert_equal :pdf_mixed,                         r.mode
    assert_equal BatchChunkingPrompt::MODEL_TEXT,    r.pages.first.model
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  test "page with has_images, text_chars<=500, img_ratio=0.50 routes to MODEL_TEXT (Sonnet — not scanned_dense)" do
    Thread.current[:pdf_image_pages] = Set.new([ 1 ])
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 2 }
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: true, text_layer_chars: 200, image_area_ratio: 0.50 }
    end
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "doc.pdf")
    assert_equal BatchChunkingPrompt::MODEL_TEXT, r.pages.first.model
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  test "page with image_area_ratio=0.25 and text_chars=600 routes to MODEL_TEXT (Sonnet — not scanned_dense)" do
    Thread.current[:pdf_image_pages] = Set.new([ 1 ])
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 2 }
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: true, text_layer_chars: 600, image_area_ratio: 0.25 }
    end
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "doc.pdf")
    assert_equal BatchChunkingPrompt::MODEL_TEXT, r.pages.first.model
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  test "route_page: scanned_dense boundary (text_chars=99, img_ratio=0.71) routes to MODEL_MULTIMODAL (Opus)" do
    Thread.current[:pdf_image_pages] = Set.new
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 2 }
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: false, text_layer_chars: 99, image_area_ratio: 0.71 }
    end
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "doc.pdf")
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, r.pages.first.model
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  test "route_page: just below scanned_dense threshold (text_chars=100, img_ratio=0.71) routes to MODEL_TEXT" do
    Thread.current[:pdf_image_pages] = Set.new
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 2 }
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: false, text_layer_chars: 100, image_area_ratio: 0.71 }
    end
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "doc.pdf")
    assert_equal BatchChunkingPrompt::MODEL_TEXT, r.pages.first.model
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  # ---------------------------------------------------------------------------
  # New: multi-page no XObjects → pdf_mixed (the PPT/LibreOffice bug case)
  # ---------------------------------------------------------------------------

  test "converted Office PDF re-classified with .pptx filename uses pdf path not office" do
    Thread.current[:pdf_image_pages] = Set.new
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 4 }
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(
      binary:       "%PDF",
      content_type: "application/pdf",
      filename:     "deck.pptx"
    )
    assert_equal :pdf_mixed, r.mode
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
  end

  test "multi-page PDF with no XObjects classifies as pdf_mixed with MODEL_TEXT result model" do
    # image_pages empty simulates LibreOffice flatten — no XObjects detected
    # Result.model for :pdf_mixed is MODEL_TEXT (authoritative model is per page.model, not Result.model)
    Thread.current[:pdf_image_pages] = Set.new
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 4 }
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "deck.pdf")
    assert_equal :pdf_mixed,                         r.mode
    assert_equal BatchChunkingPrompt::MODEL_TEXT,    r.model
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
  end

  # ---------------------------------------------------------------------------
  # New: route_page — density-detected rasterized slide (no XObjects, high ratio)
  # ---------------------------------------------------------------------------

  test "route_page promotes rasterized slide to MODEL_MULTIMODAL via density (has_images=false, img_ratio=0.8)" do
    Thread.current[:pdf_image_pages] = Set.new  # no XObjects → has_images=false for all pages
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 4 }
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: false, text_layer_chars: 50, image_area_ratio: 0.80 }
    end
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "slide.pdf")
    assert_equal :pdf_mixed,                              r.mode
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL,  r.pages.first.model
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  # ---------------------------------------------------------------------------
  # New: route_page — pure text page (no XObjects, zero density) → MODEL_TEXT
  # ---------------------------------------------------------------------------

  test "route_page keeps pure-text page at MODEL_TEXT when density reports no images" do
    Thread.current[:pdf_image_pages] = Set.new
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 4 }
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: false, text_layer_chars: 1200, image_area_ratio: 0.0 }
    end
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "manual.pdf")
    assert_equal :pdf_mixed,                         r.mode
    assert_equal BatchChunkingPrompt::MODEL_TEXT,    r.pages.first.model
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  # ---------------------------------------------------------------------------
  # Fase 1 visual triage (docs/rag/plan_conocimiento_visual.md) — behind
  # IngestionVisualTriageFlag. Flag off must be byte-identical to today.
  # ---------------------------------------------------------------------------

  def with_visual_triage_flag(value)
    original = ENV.fetch("INGESTION_VISUAL_TRIAGE_ENABLED", nil)
    if value.nil?
      ENV.delete("INGESTION_VISUAL_TRIAGE_ENABLED")
    else
      ENV["INGESTION_VISUAL_TRIAGE_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("INGESTION_VISUAL_TRIAGE_ENABLED")
    else
      ENV["INGESTION_VISUAL_TRIAGE_ENABLED"] = original
    end
  end

  def stub_geometry_by_binary(map)
    orig = FileMultimodalRouter.instance_method(:geometry_signal)
    FileMultimodalRouter.define_method(:geometry_signal) do |binary|
      map.fetch(binary) { { long_segments: 0, small_images: 0 } }
    end
    yield
  ensure
    FileMultimodalRouter.define_method(:geometry_signal, orig)
  end

  def stub_geometry_forbidden(message)
    orig = FileMultimodalRouter.instance_method(:geometry_signal)
    FileMultimodalRouter.define_method(:geometry_signal) { |_| raise message }
    yield
  ensure
    FileMultimodalRouter.define_method(:geometry_signal, orig)
  end

  def stub_uniform_pages(count)
    orig = PdfPageSplitterService.instance_method(:each_page)
    # page_count only gates the "total_pages <= 1 → pdf_text_only" early return in
    # classify_pdf; it must report >1 even when a test yields a single page via
    # each_page, or the multi-page :pdf_mixed path (and route_page) never runs.
    PdfPageSplitterService.define_method(:page_count) { [ count, 2 ].max }
    PdfPageSplitterService.define_method(:each_page) do |&b|
      count.times { |i| b.call(i + 1, "geo_p#{i + 1}") }
    end
    yield
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
  end

  test "flag off: a geometrically complex page never calls geometry_signal and stays MODEL_TEXT" do
    with_visual_triage_flag(nil) do
      Thread.current[:pdf_image_pages] = Set.new
      PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
        { has_images: true, text_layer_chars: 900, image_area_ratio: 0.2 }
      end

      stub_uniform_pages(1) do
        stub_geometry_forbidden("must not be called when flag is off") do
          r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "seguridades.pdf")

          assert_equal BatchChunkingPrompt::MODEL_TEXT, r.pages.first.model
        end
      end
    end
  ensure
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  test "flag on: a page passing both geometric thresholds escalates to MODEL_MULTIMODAL" do
    with_visual_triage_flag("true") do
      Thread.current[:pdf_image_pages] = Set.new
      PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
        { has_images: true, text_layer_chars: 900, image_area_ratio: 0.2 }
      end

      # 10 pages so the 0.15 default budget floors to exactly 1 escalation slot.
      stub_uniform_pages(10) do
        geometry = { "geo_p1" => { long_segments: 15, small_images: 5 } }
        stub_geometry_by_binary(geometry) do
          r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "seguridades.pdf")

          assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, r.pages.first.model
          assert r.pages.drop(1).all? { |p| p.model == BatchChunkingPrompt::MODEL_TEXT }
        end
      end
    end
  ensure
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  test "flag on: a page below the small-image threshold does not escalate" do
    with_visual_triage_flag("true") do
      Thread.current[:pdf_image_pages] = Set.new
      PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
        { has_images: true, text_layer_chars: 900, image_area_ratio: 0.2 }
      end

      stub_uniform_pages(10) do
        geometry = { "geo_p1" => { long_segments: 15, small_images: 2 } } # below SMALL_IMAGE_MIN_COUNT (3)
        stub_geometry_by_binary(geometry) do
          r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "seguridades.pdf")

          assert_equal BatchChunkingPrompt::MODEL_TEXT, r.pages.first.model
        end
      end
    end
  ensure
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  test "flag on: budget caps escalation to the highest-complexity candidate first" do
    with_visual_triage_flag("true") do
      Thread.current[:pdf_image_pages] = Set.new
      PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
        { has_images: true, text_layer_chars: 900, image_area_ratio: 0.2 }
      end

      # 10 pages → budget = floor(10 * 0.15) = 1. Three candidates qualify;
      # only the highest complexity_score (p3, score 35) may escalate.
      stub_uniform_pages(10) do
        geometry = {
          "geo_p1" => { long_segments: 12, small_images: 3 },   # score 15
          "geo_p2" => { long_segments: 14, small_images: 4 },   # score 18
          "geo_p3" => { long_segments: 25, small_images: 10 }   # score 35 — highest
        }
        stub_geometry_by_binary(geometry) do
          r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "seguridades.pdf")
          by_number = r.pages.index_by(&:number)

          assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, by_number[3].model
          assert_equal BatchChunkingPrompt::MODEL_TEXT,       by_number[1].model
          assert_equal BatchChunkingPrompt::MODEL_TEXT,       by_number[2].model
        end
      end
    end
  ensure
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  test "flag on: a scanned-dense page never calls geometry_signal and stays MODEL_MULTIMODAL" do
    with_visual_triage_flag("true") do
      Thread.current[:pdf_image_pages] = Set.new
      PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
        { has_images: false, text_layer_chars: 50, image_area_ratio: 0.8 }
      end

      stub_uniform_pages(1) do
        stub_geometry_forbidden("must not be called for scanned-dense pages") do
          r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "seguridades.pdf")

          assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, r.pages.first.model
        end
      end
    end
  ensure
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end
end
