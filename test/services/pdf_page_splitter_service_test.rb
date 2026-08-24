# frozen_string_literal: true

require "test_helper"

class PdfPageSplitterServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # ---------------------------------------------------------------------------
  # Stubs for HexaPDF
  # ---------------------------------------------------------------------------

  class FakePage
    attr_reader :deleted_keys

    def initialize(num)
      @num          = num
      @deleted_keys = []
    end

    def delete(key) = @deleted_keys << key
  end

  class FakePages
    def initialize(count) = (@pages = Array.new(count) { |i| FakePage.new(i + 1) })

    delegate :count, to: :@pages
    delegate :[], to: :@pages
    delegate :to_a, to: :@pages
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
    # Memoized so a test can inspect the very page objects the service touched;
    # a fresh FakePages per call would discard the recorded deletions.
    def initialize(count) = (@count = count)
    def pages = (@pages ||= FakePages.new(@count))
  end

  attr_reader :sources

  def bump_call_count = (@call_count += 1)

  setup do
    @orig_hexapdf_new = HexaPDF::Document.method(:new)
    @call_count       = 0
    @sources          = []
    self_ref          = self

    HexaPDF::Document.define_singleton_method(:new) do |**kwargs|
      self_ref.bump_call_count
      next FakeTargetDocument.new unless kwargs.key?(:io)

      FakeSourceDocument.new(3).tap { |doc| self_ref.sources << doc }
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

  # HexaPDF copies the shared resource tree into every extracted page, so a caller
  # that needs two pages out of 515 must pay for two, not 515. Serializing a page
  # it did not ask for is the whole cost.
  test "only: serializes just the requested pages, in ascending order" do
    yielded = []
    PdfPageSplitterService.new("fake_binary").each_page(only: [ 3, 1 ]) do |page_num, binary|
      yielded << page_num
      assert binary.start_with?("%PDF")
    end

    assert_equal [ 1, 3 ], yielded
    # 1 source + 2 targets: page 2 is never serialized.
    assert_equal 3, @call_count
  end

  test "only: deduplicates repeated page numbers" do
    yielded = []
    PdfPageSplitterService.new("fake_binary").each_page(only: [ 2, 2, 2 ]) { |n, _| yielded << n }

    assert_equal [ 2 ], yielded
    assert_equal 2, @call_count, "one source + one target"
  end

  test "only: skips page numbers outside the document instead of raising" do
    yielded = []
    assert_nothing_raised do
      PdfPageSplitterService.new("fake_binary").each_page(only: [ 0, 2, 99, nil ]) { |n, _| yielded << n }
    end

    assert_equal [ 2 ], yielded
  end

  test "only: an empty selection serializes nothing" do
    yielded = []
    PdfPageSplitterService.new("fake_binary").each_page(only: []) { |n, _| yielded << n }

    assert_empty yielded
    assert_equal 1, @call_count, "the source is opened, no target is built"
  end

  test "only: nil is the unrestricted legacy behavior" do
    yielded = []
    PdfPageSplitterService.new("fake_binary").each_page(only: nil) { |n, _| yielded << n }

    assert_equal [ 1, 2, 3 ], yielded
  end

  test "every import drops the whole-document-only keys, on all three iterators" do
    PdfPageSplitterService.new("fake_binary").each_page { }
    PdfPageSplitterService.new("fake_binary").each_split_page(&:cleanup)
    PdfPageSplitterService.new("fake_binary").each_part(max_bytes: 5.megabytes) { }

    assert_equal 3, sources.size, "each iterator opens its own source document"
    sources.each_with_index do |source, idx|
      touched = source.pages.to_a.select { |page| page.deleted_keys.any? }
      assert_equal 3, touched.size, "source #{idx}: every imported page must be pruned"
      touched.each do |page|
        assert_equal PdfPageSplitterService::WHOLE_DOCUMENT_ONLY_KEYS, page.deleted_keys
      end
    end
  end

  test "only: prunes the requested pages and leaves the others untouched" do
    PdfPageSplitterService.new("fake_binary").each_page(only: [ 2 ]) { }

    pages = sources.first.pages.to_a
    assert_equal PdfPageSplitterService::WHOLE_DOCUMENT_ONLY_KEYS, pages[1].deleted_keys
    assert_empty pages[0].deleted_keys, "page 1 was never imported"
    assert_empty pages[2].deleted_keys, "page 3 was never imported"
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

# Real HexaPDF, because the defect is about what `import` reaches through an
# article thread — the one thing the stubs above cannot reproduce. BulkUpload 8:
# one unparseable page pulled 435 pages into a "single page" PDF and the worker
# took a SIGKILL at its 2 GiB cgroup limit.
class PdfPageSplitterServiceBeadPruneTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  HEAVY_PAYLOAD_BYTES = 200_000
  PAGE_TEXT           = "ANCHOR PAGE TEXT"

  # Page 1 is light and carries readable text; page 2 carries an incompressible
  # payload. An article thread links them, which is how importing page 1 reaches
  # page 2 even though page 1 references none of its content.
  def pdf_with_article_thread
    rng = Random.new(4242)
    doc = HexaPDF::Document.new

    light = doc.pages.add
    light.canvas.font("Helvetica", size: 12).text(PAGE_TEXT, at: [ 72, 700 ])

    heavy = doc.pages.add
    heavy.contents = rng.bytes(HEAVY_PAYLOAD_BYTES)

    thread      = doc.add({})
    first_bead  = doc.add({ P: light, T: thread })
    second_bead = doc.add({ P: heavy, T: thread })
    first_bead[:N]  = second_bead
    first_bead[:V]  = second_bead
    second_bead[:N] = first_bead
    second_bead[:V] = first_bead
    thread[:F] = first_bead
    light[:B]  = [ first_bead ]
    heavy[:B]  = [ second_bead ]
    doc.catalog[:Threads] = [ thread ]

    io = StringIO.new("".b)
    doc.write(io, validate: false)
    io.string
  end

  def first_page_of(binary)
    pages = {}
    PdfPageSplitterService.new(binary).each_page { |number, bytes| pages[number] = bytes }
    pages[1]
  end

  def page_objects_in(binary)
    doc = HexaPDF::Document.new(io: StringIO.new(binary))
    count = 0
    doc.each(only_current: true) { |obj| count += 1 if obj.is_a?(HexaPDF::Type::Page) }
    count
  end

  def without_prune
    original = PdfPageSplitterService::WHOLE_DOCUMENT_ONLY_KEYS
    PdfPageSplitterService.send(:remove_const, :WHOLE_DOCUMENT_ONLY_KEYS)
    PdfPageSplitterService.const_set(:WHOLE_DOCUMENT_ONLY_KEYS, [].freeze)
    yield
  ensure
    PdfPageSplitterService.send(:remove_const, :WHOLE_DOCUMENT_ONLY_KEYS)
    PdfPageSplitterService.const_set(:WHOLE_DOCUMENT_ONLY_KEYS, original)
  end

  # Guards against a vacuous suite: if the fixture did not reproduce the defect,
  # the assertions below would pass with the prune removed.
  test "the fixture reproduces the defect when the prune is disabled" do
    unpruned = without_prune { first_page_of(pdf_with_article_thread) }

    assert_operator unpruned.bytesize, :>, HEAVY_PAYLOAD_BYTES,
                    "expected the thread to drag page 2's payload into page 1"
    assert_operator page_objects_in(unpruned), :>, 1,
                    "expected orphan Page objects to travel with page 1"
  end

  test "an article thread does not drag other pages into an extracted page" do
    pruned = first_page_of(pdf_with_article_thread)

    assert_equal 1, page_objects_in(pruned), "exactly one Page object may survive"
    assert_operator pruned.bytesize, :<, HEAVY_PAYLOAD_BYTES / 4,
                    "page 2's payload must not travel with page 1"
  end

  test "pruning removes no readable content" do
    binary = pdf_with_article_thread
    pruned   = first_page_of(binary)
    unpruned = without_prune { first_page_of(binary) }

    assert_equal text_of(unpruned), text_of(pruned),
                 "the prune must not change a single character of the page"
    assert_includes text_of(pruned), PAGE_TEXT
  end

  test "the page tree still holds exactly one page after pruning" do
    pruned = first_page_of(pdf_with_article_thread)

    assert_equal 1, HexaPDF::Document.new(io: StringIO.new(pruned)).pages.count
  end

  private

  def text_of(binary)
    Tempfile.create([ "bead-prune-", ".pdf" ]) do |file|
      file.binmode
      file.write(binary)
      file.flush
      PDF::Reader.new(file.path).pages.first.text.to_s.strip
    end
  end
end
