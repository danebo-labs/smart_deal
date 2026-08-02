require "test_helper"

class PdfPageRasterizerTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("test/fixtures/files/pdf_layout_extractor_sample.pdf")
  MEDIA_BOX    = [ 0, 0, 600, 400 ].freeze

  setup do
    @pages = split_pages(File.binread(FIXTURE_PATH))
  end

  # The production requirement of Fase 5: Dockerfile:19 installs Debian's
  # `libvips`, which must carry the poppler loader (VipsForeignLoadPdfBuffer) or
  # this whole tier cannot render a page. Verified for `debian:trixie-slim`
  # (libvips -> libvips42t64 -> libpoppler-glib8) in I-34; this test is the same
  # assertion made executable wherever the suite runs.
  test "libvips exposes the poppler pdfload_buffer loader" do
    image = Vips::Image.pdfload_buffer(@pages[0], page: 0, dpi: 72)

    assert_equal 600, image.width
    assert_equal 400, image.height
  end

  test "page renders at PAGE_DPI and reports what it rendered" do
    raster = PdfPageRasterizer.new(@pages[0], media_box: MEDIA_BOX).page

    assert_equal PdfPageRasterizer::PAGE_DPI, raster.dpi
    assert_equal (600 * PdfPageRasterizer::PAGE_DPI / 72.0).round, raster.width
    assert_equal "image/jpeg", raster.media_type
    assert raster.data.present?
    assert_operator raster.bytes, :<=, ImageCompressionService::MAX_BINARY_BYTES
  end

  # DPI degrades, never grows: a media box four times the reference page's long
  # edge must cost fewer pixels per point, not more total pixels.
  test "an oversized media box degrades DPI instead of billing a bigger raster" do
    raster = PdfPageRasterizer.new(@pages[0], media_box: [ 0, 0, 4000, 4000 ]).page

    assert_operator raster.dpi, :<, PdfPageRasterizer::PAGE_DPI
    assert_operator [ raster.width, raster.height ].max, :<=, PdfPageRasterizer::MAX_LONG_EDGE_PX
  end

  # Coordinate flip, pinned by arithmetic rather than by eye. The box is the TOP
  # half in HexaPDF space (y up), so with the margin it starts at the very top of
  # the raster and is CROP_MARGIN_PT tall past the middle. Read as top-down the
  # same box would start halfway down and run off the bottom edge, clamping to a
  # visibly different height — this assertion fails on any inverted flip.
  test "crop converts bottom-up page space to top-down pixels" do
    scale  = PdfPageRasterizer::CROP_DPI / 72.0
    raster = PdfPageRasterizer.new(@pages[2], media_box: MEDIA_BOX).crop([ 0, 200, 600, 400 ])

    assert_equal (600 * scale).round, raster.width
    assert_equal ((200 + PdfPageRasterizer::CROP_MARGIN_PT) * scale).round, raster.height
  end

  # Same halves, judged by ink instead of by geometry: fixture page 3 prints
  # "TOP LABEL" high and the longer "BOTTOM LABEL" low, so the top half is the
  # whiter of the two. Inverting the flip swaps them.
  test "crop reads the half of the page it was asked for" do
    rasterizer = PdfPageRasterizer.new(@pages[2], media_box: MEDIA_BOX)

    top_mean    = mean_luminance(rasterizer.crop([ 0, 200, 600, 400 ]))
    bottom_mean = mean_luminance(rasterizer.crop([ 0, 0, 600, 200 ]))

    assert_operator top_mean, :>, bottom_mean,
                    "expected the half printing the shorter label to carry less ink"
  end

  test "crop of a printed label carries ink and crop of blank page space does not" do
    rasterizer = PdfPageRasterizer.new(@pages[2], media_box: MEDIA_BOX)

    assert_operator mean_luminance(rasterizer.crop([ 100, 377.3, 165.4, 391.2 ])), :<, 250.0
    assert_equal 255.0, mean_luminance(rasterizer.crop([ 400, 100, 550, 200 ]))
  end

  test "crop rejects a degenerate box instead of rendering a sliver" do
    rasterizer = PdfPageRasterizer.new(@pages[0], media_box: MEDIA_BOX)

    assert_nil rasterizer.crop([ 100, 100, 102, 140 ]), "a 2 pt wide graphic is not a crop"
    assert_nil rasterizer.crop([ 100, 100, 200 ]), "a malformed box is not a crop"
  end

  # One poppler decode per DPI, reused by every crop of the page: 15-24 crops is
  # the measured norm for a content page of the reference document.
  test "repeated crops of one page decode the PDF once per DPI" do
    decodes = 0
    original = Vips::Image.method(:pdfload_buffer)
    Vips::Image.define_singleton_method(:pdfload_buffer) do |*args, **kwargs|
      decodes += 1
      original.call(*args, **kwargs)
    end

    rasterizer = PdfPageRasterizer.new(@pages[0], media_box: MEDIA_BOX)
    3.times { rasterizer.crop([ 500, 50, 560, 98 ]) }
    rasterizer.page

    assert_equal 2, decodes, "expected one decode at CROP_DPI and one at PAGE_DPI"
  ensure
    Vips::Image.define_singleton_method(:pdfload_buffer, original) if original
  end

  test "union_bbox frames a graphic together with its label" do
    assert_equal [ 5.0, 20.0, 35.0, 40.0 ], PdfPageRasterizer.union_bbox([ 10, 20, 30, 40 ], [ 5, 25, 35, 38 ])
    assert_equal [ 10.0, 20.0, 30.0, 40.0 ], PdfPageRasterizer.union_bbox([ 10, 20, 30, 40 ], nil)
  end

  # A libvips built without the poppler loader, or a page poppler cannot decode,
  # must surface as this class's own error — VisionTopologyExtractor degrades the
  # page on it rather than failing the whole ingestion.
  test "a loader failure raises RasterError instead of leaking a Vips error" do
    original = Vips::Image.method(:pdfload_buffer)
    Vips::Image.define_singleton_method(:pdfload_buffer) do |*, **|
      raise Vips::Error, 'class "VipsForeignLoadPdfBuffer" not found'
    end

    error = assert_raises(PdfPageRasterizer::RasterError) do
      PdfPageRasterizer.new(@pages[0], media_box: MEDIA_BOX).page
    end
    assert_includes error.message, "pdfload_buffer failed"
  ensure
    Vips::Image.define_singleton_method(:pdfload_buffer, original) if original
  end

  private

  def split_pages(binary)
    pages = []
    PdfPageSplitterService.new(binary).each_page { |_num, page_binary| pages << page_binary }
    pages
  end

  def mean_luminance(raster)
    Vips::Image.new_from_buffer(Base64.decode64(raster.data), "").avg
  end
end
