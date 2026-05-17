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

    def write(io, **) = io.write("%PDF-1.4 single page fake binary")
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
end
