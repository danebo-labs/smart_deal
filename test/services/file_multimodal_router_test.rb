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
  # Image MIME types → :image mode, Opus
  # ---------------------------------------------------------------------------

  test "classifies image/jpeg as image mode with MODEL_MULTIMODAL" do
    r = FileMultimodalRouter.classify(binary: "\xFF\xD8", content_type: "image/jpeg", filename: "photo.jpg")
    assert_equal :image,                                   r.mode
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL,    r.model
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
  # Conservative downgrade in route_page (tested via pdf_mixed)
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

  test "page with has_images and text_chars<=500 routes to MODEL_MULTIMODAL (no downgrade)" do
    Thread.current[:pdf_image_pages] = Set.new([ 1 ])
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 2 }
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: true, text_layer_chars: 200, image_area_ratio: 0.50 }
    end
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "doc.pdf")
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, r.pages.first.model
  ensure
    PdfPageSplitterService.define_method(:each_page, orig)
    PdfPageSplitterService.define_method(:page_count, @orig_page_count)
    PageImageDensityAnalyzer.define_singleton_method(:analyze, @orig_analyzer)
  end

  test "page with image_area_ratio>=0.20 even with many text_chars routes to MODEL_MULTIMODAL" do
    Thread.current[:pdf_image_pages] = Set.new([ 1 ])
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 2 }
    PageImageDensityAnalyzer.define_singleton_method(:analyze) do |_|
      { has_images: true, text_layer_chars: 600, image_area_ratio: 0.25 }
    end
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "doc.pdf")
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL, r.pages.first.model
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

  test "multi-page PDF with no XObjects classifies as pdf_mixed" do
    # image_pages empty simulates LibreOffice flatten — no XObjects detected
    Thread.current[:pdf_image_pages] = Set.new
    orig = PdfPageSplitterService.instance_method(:each_page)
    PdfPageSplitterService.define_method(:page_count) { 4 }
    PdfPageSplitterService.define_method(:each_page) { |&b| b.call(1, "fake") }

    r = FileMultimodalRouter.classify(binary: "%PDF", content_type: "application/pdf", filename: "deck.pdf")
    assert_equal :pdf_mixed,                              r.mode
    assert_equal BatchChunkingPrompt::MODEL_MULTIMODAL,  r.model
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
end
