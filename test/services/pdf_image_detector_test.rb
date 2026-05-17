# frozen_string_literal: true

require "test_helper"

class PdfImageDetectorTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Fakes — two-level dictionary: Resources > XObject > Image XObjects
  # ---------------------------------------------------------------------------

  class FakeXObject
    attr_reader :subtype

    def initialize(subtype:)
      @subtype = subtype
    end

    def is_a?(klass) = klass == HexaPDF::Dictionary || super
    def [](key)     = key == :Subtype ? @subtype : nil
    delegate :to_s, to: :@subtype
  end

  # Generic fake dictionary: is_a?(HexaPDF::Dictionary)=true, each yields [name, value] pairs
  class FakeDict
    def initialize(entries = {})
      @entries = entries
    end

    def is_a?(klass) = klass == HexaPDF::Dictionary || super
    delegate :[], to: :@entries
    def each(&block) = @entries.each(&block)
  end

  class FakePage
    def initialize(has_image:)
      if has_image
        xobjects  = FakeDict.new({ img: FakeXObject.new(subtype: :Image) })
        resources = FakeDict.new({ XObject: xobjects })
      else
        resources = FakeDict.new({})
      end
      @resources = resources
    end

    def [](key) = key == :Resources ? @resources : nil
  end

  class FakeDocument
    def initialize(pages_config)
      @pages = pages_config.map { |cfg| FakePage.new(has_image: cfg[:has_image]) }
    end

    def pages = @pages
  end

  # ---------------------------------------------------------------------------
  # Setup / Teardown
  # ---------------------------------------------------------------------------

  setup do
    @orig_hexapdf_new = HexaPDF::Document.method(:new)
  end

  teardown do
    HexaPDF::Document.define_singleton_method(:new, @orig_hexapdf_new)
  end

  def stub_document(pages_config)
    doc = FakeDocument.new(pages_config)
    HexaPDF::Document.define_singleton_method(:new) { |**| doc }
  end

  # ---------------------------------------------------------------------------
  # has_images?
  # ---------------------------------------------------------------------------

  test "returns true when at least one page has an Image XObject" do
    stub_document([ { has_image: false }, { has_image: true }, { has_image: false } ])
    assert PdfImageDetector.has_images?("fake")
  end

  test "returns false when no pages have Image XObjects" do
    stub_document([ { has_image: false }, { has_image: false } ])
    assert_not PdfImageDetector.has_images?("fake")
  end

  # ---------------------------------------------------------------------------
  # image_pages (1-indexed)
  # ---------------------------------------------------------------------------

  test "returns set of 1-indexed page numbers with images" do
    stub_document([ { has_image: true }, { has_image: false }, { has_image: true } ])
    pages = PdfImageDetector.image_pages("fake")
    assert_equal Set.new([ 1, 3 ]), pages
  end

  test "returns empty set for PDF with no images" do
    stub_document([ { has_image: false }, { has_image: false } ])
    assert_empty PdfImageDetector.image_pages("fake")
  end

  test "returns empty set when HexaPDF raises an error" do
    HexaPDF::Document.define_singleton_method(:new) { |**| raise HexaPDF::Error, "corrupt" }
    assert_empty PdfImageDetector.image_pages("corrupt bytes")
  end

  # ---------------------------------------------------------------------------
  # Integration — real HexaPDF document (no stub) — guards against API drift
  # ---------------------------------------------------------------------------

  test "detects image pages using real HexaPDF document with embedded Image XObject" do
    pdf_bytes = build_minimal_pdf_with_image
    assert PdfImageDetector.has_images?(pdf_bytes), "expected has_images? true for PDF with Image XObject"
    pages = PdfImageDetector.image_pages(pdf_bytes)
    assert_includes pages, 1
    assert_equal 1, pages.size
  end

  test "returns empty set for real HexaPDF document with no images" do
    pdf_bytes = build_minimal_pdf_no_image
    assert_not PdfImageDetector.has_images?(pdf_bytes)
    assert_empty PdfImageDetector.image_pages(pdf_bytes)
  end

  def build_minimal_pdf_with_image
    doc  = HexaPDF::Document.new
    page = doc.pages.add

    img = doc.add({ Type: :XObject, Subtype: :Image, Width: 1, Height: 1,
                    ColorSpace: :DeviceGray, BitsPerComponent: 8 })
    page[:Resources] = doc.wrap({ XObject: { Im1: img } })

    io = StringIO.new
    doc.write(io)
    io.string
  end

  def build_minimal_pdf_no_image
    doc = HexaPDF::Document.new
    doc.pages.add
    io = StringIO.new
    doc.write(io)
    io.string
  end
end
