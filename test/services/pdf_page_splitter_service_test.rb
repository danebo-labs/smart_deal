# frozen_string_literal: true

require "test_helper"

class PdfPageSplitterServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Stubs for HexaPDF
  # ---------------------------------------------------------------------------

  class FakePage
    def initialize(num) = (@num = num)
  end

  class FakePages
    def initialize(count) = (@pages = Array.new(count) { |i| FakePage.new(i + 1) })

    delegate :count, to: :@pages
    delegate :[], to: :@pages
  end

  class FakeTargetDocument
    attr_reader :imported_pages

    def initialize = (@imported_pages = [])

    def pages  = self
    def <<(page) = @imported_pages.push(page)

    def import(page) = page  # cross-document "import" is identity in this fake

    def write(destination, **)
      binary = "%PDF-1.4 single page fake binary"
      destination.respond_to?(:write) ? destination.write(binary) : File.binwrite(destination, binary)
    end
  end

  class FakeSourceDocument
    def initialize(count) = (@count = count)
    def pages = FakePages.new(@count)
  end

  setup do
    @orig_hexapdf_new = HexaPDF::Document.method(:new)
    @call_count       = 0
    self_ref          = self

    HexaPDF::Document.define_singleton_method(:new) do |**kwargs|
      self_ref.instance_variable_set(:@call_count, self_ref.instance_variable_get(:@call_count) + 1)
      kwargs.key?(:io) ? FakeSourceDocument.new(3) : FakeTargetDocument.new
    end
  end

  teardown do
    HexaPDF::Document.define_singleton_method(:new, @orig_hexapdf_new)
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  test "yields once per page in the source document" do
    yielded = []
    PdfPageSplitterService.new("fake_binary").each_page do |page_num, binary|
      yielded << { page_num: page_num, binary: binary }
    end

    assert_equal 3, yielded.count
  end

  test "page_numbers are 1-indexed and sequential" do
    page_nums = []
    PdfPageSplitterService.new("fake_binary").each_page { |n, _| page_nums << n }
    assert_equal [ 1, 2, 3 ], page_nums
  end

  test "each yielded binary starts with %PDF" do
    PdfPageSplitterService.new("fake_binary").each_page do |_, binary|
      assert binary.start_with?("%PDF"), "expected single-page PDF bytes"
    end
  end

  test "creates one target document per page" do
    PdfPageSplitterService.new("fake_binary").each_page { }
    # 1 source + 3 targets = 4 HexaPDF::Document.new calls
    assert_equal 4, @call_count
  end

  test "each_split_page yields disk-backed proxies with lazy binary and explicit cleanup" do
    pages = []
    PdfPageSplitterService.new("fake_binary").each_split_page { |page| pages << page }

    assert_equal [ 1, 2, 3 ], pages.map(&:number)
    assert pages.all? { |page| File.exist?(page.path) }
    assert pages.all? { |page| page.byte_size.positive? }
    assert pages.all? { |page| page.binary.start_with?("%PDF") }

    paths = pages.map(&:path)
    pages.each(&:cleanup)
    assert paths.none? { |path| File.exist?(path) }
  ensure
    Array(pages).each(&:cleanup)
  end
end

# Separate class because #each_part is about the byte size of a re-serialized
# page range — the one thing the HexaPDF stubs above cannot reproduce.
class PdfPageSplitterServicePartsTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # Page payloads are incompressible bytes from a seeded PRNG, so sizes are
  # predictable and the test stays deterministic.
  def pdf_with_page_sizes(sizes)
    rng = Random.new(1234)
    doc = HexaPDF::Document.new

    sizes.each { |bytes| doc.pages.add.contents = rng.bytes(bytes) }

    io = StringIO.new("".b)
    doc.write(io, validate: false)
    io.string
  end

  def pdf_with_pages(count, page_bytes:) = pdf_with_page_sizes(Array.new(count, page_bytes))

  def parts_for(binary, max_bytes:)
    [].tap { |acc| PdfPageSplitterService.new(binary).each_part(max_bytes: max_bytes) { |p| acc << p } }
  end

  def page_count_of(binary) = HexaPDF::Document.new(io: StringIO.new(binary)).pages.count

  # ---------------------------------------------------------------------------
  # Splitting
  # ---------------------------------------------------------------------------

  test "parts cover every page exactly once, contiguous and in order" do
    parts = parts_for(pdf_with_pages(10, page_bytes: 20_000), max_bytes: 60_000)

    assert_operator parts.size, :>, 1, "expected the source to need splitting"
    assert_equal 1, parts.first.first_page
    assert_equal 10, parts.last.last_page
    assert_equal (1..parts.size).to_a, parts.map(&:index)
    assert_equal (1..10).to_a, parts.flat_map { |part| (part.first_page..part.last_page).to_a }
  end

  test "no part exceeds max_bytes" do
    parts = parts_for(pdf_with_pages(10, page_bytes: 20_000), max_bytes: 60_000)

    parts.each do |part|
      assert_operator part.byte_size, :<=, 60_000, "part #{part.index} is over the ceiling"
    end
  end

  test "each part is a readable PDF holding its declared page count" do
    parts = parts_for(pdf_with_pages(10, page_bytes: 20_000), max_bytes: 60_000)

    parts.each do |part|
      assert part.binary.start_with?("%PDF"), "part #{part.index} is not PDF bytes"
      assert_equal part.page_count, page_count_of(part.binary)
    end
  end

  test "a source already under the ceiling yields a single part" do
    parts = parts_for(pdf_with_pages(3, page_bytes: 1_000), max_bytes: 5.megabytes)

    assert_equal 1, parts.size
    assert_equal 1, parts.first.first_page
    assert_equal 3, parts.first.last_page
  end

  test "re-splits when one heavy page busts an evenly divided range" do
    # The heavy page fits alone but not next to any sibling, so the even split
    # has to be halved twice before every piece is under the ceiling.
    parts = parts_for(pdf_with_page_sizes([ 5_000 ] * 8 + [ 45_000 ]), max_bytes: 50_000)

    parts.each do |part|
      assert_operator part.byte_size, :<=, 50_000, "part #{part.index} is over the ceiling"
    end

    assert_equal (1..9).to_a, parts.flat_map { |part| (part.first_page..part.last_page).to_a }
    assert_equal 1, parts.count { |part| part.page_count == 1 && part.last_page == 9 },
                 "the heavy page should end up isolated in its own part"
  end

  # ---------------------------------------------------------------------------
  # Failure scenarios
  # ---------------------------------------------------------------------------

  test "raises when a single page cannot fit under the ceiling" do
    error = assert_raises(PdfPageSplitterService::Error) do
      parts_for(pdf_with_pages(1, page_bytes: 80_000), max_bytes: 20_000)
    end
    assert_match(/page 1 is \d+ bytes on its own/, error.message)
  end

  test "raises on a non-positive max_bytes" do
    assert_raises(PdfPageSplitterService::Error) do
      PdfPageSplitterService.new("x").each_part(max_bytes: 0) { }
    end
  end

  test "raises on bytes that are not a PDF" do
    error = assert_raises(PdfPageSplitterService::Error) do
      parts_for("definitely not a pdf", max_bytes: 1_000)
    end
    assert_match(/cannot open PDF/, error.message)
  end
end
