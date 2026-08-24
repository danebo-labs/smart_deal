# frozen_string_literal: true

require "tempfile"

# Splits a multi-page PDF with HexaPDF.
# #each_page yields in-memory single-page binaries; pass `only:` to bound how many.
# Batch ingestion uses #each_split_page so page binaries remain disk-backed.
# #each_part cuts by page range instead, for callers bounded by a byte ceiling.
#
# A caller that needs a few known pages passes #each_page(only:), so the number
# of pages serialized is bounded by what the caller actually asked for.
class PdfPageSplitterService
  class Error < StandardError; end

  Part = Struct.new(:index, :first_page, :last_page, :binary, keyword_init: true) do
    def byte_size  = binary.bytesize
    def page_count = last_page - first_page + 1
  end

  # Keys that only mean something inside the *whole* document and that a target
  # holding a subset of its pages can never honour. They are dropped before
  # import because HexaPDF copies the transitive closure of whatever the page
  # references, and these reference the rest of the document.
  #
  # /B is the page's article-thread bead array (catalog /Threads). Each bead
  # points at the next bead and each bead points at its own page, so importing
  # one threaded page walks the entire thread and drags every page on it — plus
  # their images — into a "single page" PDF. Measured on the 515-page KONE scan
  # of BulkUpload 8 (15 MiB source, hexapdf 1.8.0, identical locally and in
  # production): page 1 extracted to 12.296 MiB carrying 435 orphan Page objects
  # and 1,864 objects total; with /B dropped it is 0.097 MiB and 29 objects. Over
  # the whole document, 6.18 GiB → 17.9 MiB, a 355x reduction. 435 of the 515
  # pages carry /B; the unthreaded appendix pages were always small, which is why
  # the inflation looked like a property of image-heavy pages.
  #
  # This removes nothing renderable: extracted text is unchanged and the page
  # rasterized through poppler at 150 dpi is a byte-identical PNG. /Annots is
  # deliberately NOT dropped — annotations can carry AcroForm widgets that do
  # paint content, and this document has an /AcroForm.
  WHOLE_DOCUMENT_ONLY_KEYS = [ :B ].freeze

  # A part re-serialized from an even page split can still land above what its
  # page count suggests. Aiming at 80% of the ceiling absorbs that without paying
  # for a second split pass.
  FILL_RATIO = 0.8

  def initialize(binary)
    @binary = binary
  end

  def page_count
    HexaPDF::Document.new(io: StringIO.new(@binary)).pages.count
  rescue StandardError => e
    Rails.logger.warn("PdfPageSplitterService.page_count: #{e.class} — #{e.message}")
    0
  end

  # @param only [Array<Integer>, nil] 1-indexed page numbers to serialize; nil
  #   yields every page. Numbers outside 1..page_count are skipped, so a caller
  #   holding stale page numbers gets fewer yields rather than an exception.
  # @yield [page_number, binary]
  # @yieldparam page_number [Integer] 1-indexed position in the original document
  # @yieldparam binary      [String]  raw PDF bytes for this single page
  def each_page(only: nil)
    source = HexaPDF::Document.new(io: StringIO.new(@binary))
    total  = source.pages.count

    page_numbers(only, total).each do |number|
      target = HexaPDF::Document.new
      import_page(target, source, number)

      io = StringIO.new("".b)
      target.write(io, validate: false)
      yield(number, io.string)
    end
  end

  # Writes every self-contained page to a tempfile and yields a SplitPage.
  # The caller owns each yielded tempfile and must call SplitPage#cleanup.
  def each_split_page
    source = HexaPDF::Document.new(io: StringIO.new(@binary))
    total  = source.pages.count

    total.times do |idx|
      target = HexaPDF::Document.new
      import_page(target, source, idx + 1)
      path = write_temp_page(target, idx + 1)

      page = SplitPage.new(
        number:    idx + 1,
        path:      path,
        byte_size: File.size(path),
        text:      extract_text(path)
      )
      yield(page)
    rescue StandardError
      File.unlink(path) if path.present? && File.exist?(path)
      raise
    end
  ensure
    @binary = nil
  end

  # Cuts the document into consecutive page ranges, each under max_bytes, so an
  # oversized PDF can enter a ZIP without tripping
  # ZipExtractionService::MAX_FILE_BYTES — which aborts the whole archive instead
  # of skipping the entry. Ranges keep the document whole for the chunker, unlike
  # the single-page methods above.
  #
  # @yield [Part] parts covering every page of the source exactly once
  def each_part(max_bytes:)
    max_bytes = max_bytes.to_i
    raise Error, "max_bytes must be positive" unless max_bytes.positive?
    raise Error, "binary already consumed by each_split_page" if @binary.blank?

    source = load_source
    total  = source.pages.count
    raise Error, "PDF has no pages" if total.zero?

    index = 0

    initial_ranges(total, max_bytes).each do |range|
      emit_part(source, range, max_bytes) do |first, last, binary|
        index += 1
        yield Part.new(index: index, first_page: first, last_page: last, binary: binary)
      end
    end
  end

  private

  def page_numbers(only, total)
    return 1..total if only.nil?

    Array(only).map(&:to_i).uniq.sort.select { |number| number.between?(1, total) }
  end

  def load_source
    HexaPDF::Document.new(io: StringIO.new(@binary))
  rescue StandardError => e
    raise Error, "cannot open PDF: #{e.class} — #{e.message}"
  end

  # First guess from the source size, so the common case writes each part once.
  def initial_ranges(total, max_bytes)
    parts = (@binary.bytesize / (max_bytes * FILL_RATIO)).ceil.clamp(1, total)
    per   = (total.to_f / parts).ceil

    (1..total).each_slice(per).map { |slice| slice.first..slice.last }
  end

  # Halves a range until every piece fits, so pages with an uneven byte
  # distribution cost extra writes instead of producing an oversized part.
  def emit_part(source, range, max_bytes, &block)
    binary = write_range(source, range)

    if binary.bytesize <= max_bytes
      block.call(range.first, range.last, binary)
      return
    end

    if range.size == 1
      raise Error,
            "page #{range.first} is #{binary.bytesize} bytes on its own, over the #{max_bytes} byte limit"
    end

    mid = range.first + (range.size / 2) - 1
    emit_part(source, range.first..mid, max_bytes, &block)
    emit_part(source, (mid + 1)..range.last, max_bytes, &block)
  end

  def write_range(source, range)
    target = HexaPDF::Document.new
    range.each { |number| import_page(target, source, number) }

    io = StringIO.new("".b)
    target.write(io, validate: false)
    io.string
  end

  # The one place a page crosses from the source document into a target, so the
  # prune cannot be forgotten by a new caller. Deleting on the source page is safe
  # because the source document is built from @binary inside this service and is
  # never written back.
  def import_page(target, source, number)
    page = source.pages[number - 1]
    WHOLE_DOCUMENT_ONLY_KEYS.each { |key| page.delete(key) }
    target.pages << target.import(page)
  end

  def write_temp_page(target, page_number)
    tempfile = Tempfile.create([ "danebo-page-#{page_number}-", ".pdf" ])
    path = tempfile.path
    tempfile.close
    target.write(path, validate: false)
    path
  rescue StandardError
    tempfile&.close
    File.unlink(path) if path.present? && File.exist?(path)
    raise
  end

  def extract_text(path)
    PDF::Reader.new(path).pages.first&.text.to_s.strip
  rescue StandardError
    ""
  end
end
