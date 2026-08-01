require "test_helper"

class PageImageDensityAnalyzerTest < ActiveSupport::TestCase
  test "returns images: [] and the existing keys unchanged when the page has no images" do
    binary = build_pdf_without_images
    result = PageImageDensityAnalyzer.analyze(binary)

    assert_equal false, result[:has_images]
    assert_equal [], result[:images]
    assert_kind_of Integer, result[:text_layer_chars]
    assert_kind_of Float, result[:image_area_ratio]
  end

  test "captures placement bbox and size_class for a small painted image" do
    binary = build_pdf_with_image(width: 100, height: 80, at: [ 500, 50 ], draw_width: 60, draw_height: 48)
    result = PageImageDensityAnalyzer.analyze(binary)

    assert_equal 1, result[:images].size
    image = result[:images].first
    assert_equal 100, image[:width]
    assert_equal 80, image[:height]
    assert_equal :small, image[:size_class]
    assert_equal [ 500, 50, 560, 98 ], image[:bbox]
  end

  test "classifies a large painted image correctly" do
    binary = build_pdf_with_image(width: 2000, height: 1000, at: [ 10, 50 ], draw_width: 200, draw_height: 100)
    result = PageImageDensityAnalyzer.analyze(binary)

    image = result[:images].first
    assert_equal :large, image[:size_class]
    assert_equal [ 10, 50, 210, 150 ], image[:bbox]
  end

  test "preserves has_images/text_layer_chars/image_area_ratio semantics unchanged" do
    binary = build_pdf_with_image(width: 100, height: 80, at: [ 0, 0 ], draw_width: 60, draw_height: 48)
    result = PageImageDensityAnalyzer.analyze(binary)

    assert_equal true, result[:has_images]
    assert result[:image_area_ratio] > 0
  end

  test "an XObject declared in Resources but never painted gets a nil bbox, not a crash" do
    doc  = HexaPDF::Document.new
    page = doc.pages.add
    img  = doc.add({ Type: :XObject, Subtype: :Image, Width: 10, Height: 10,
                      ColorSpace: :DeviceGray, BitsPerComponent: 8 })
    page[:Resources] = doc.wrap({ XObject: { Im1: img } })
    io = StringIO.new("".b)
    doc.write(io, validate: false)

    result = PageImageDensityAnalyzer.analyze(io.string)

    assert_equal true, result[:has_images]
    assert_nil result[:images].first[:bbox]
  end

  test "an unparseable binary falls back to the default result with images: []" do
    result = PageImageDensityAnalyzer.analyze("not a pdf")

    assert_equal({ has_images: false, text_layer_chars: 0, image_area_ratio: 0.0, images: [] }, result)
  end

  private

  def build_pdf_without_images
    doc  = HexaPDF::Document.new
    page = doc.pages.add
    page.canvas.font("Helvetica", size: 12).text("hello", at: [ 10, 10 ])
    io = StringIO.new("".b)
    doc.write(io, validate: false)
    io.string
  end

  def build_pdf_with_image(width:, height:, at:, draw_width:, draw_height:)
    doc  = HexaPDF::Document.new
    page = doc.pages.add
    img  = doc.add({ Type: :XObject, Subtype: :Image, Width: width, Height: height,
                      ColorSpace: :DeviceGray, BitsPerComponent: 8 })
    page.canvas.xobject(img, at: at, width: draw_width, height: draw_height)
    io = StringIO.new("".b)
    doc.write(io, validate: false)
    io.string
  end
end
