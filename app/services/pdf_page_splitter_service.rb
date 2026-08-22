# frozen_string_literal: true

require "tempfile"

# Splits a multi-page PDF with HexaPDF.
# Legacy #each_page yields in-memory single-page binaries for short synchronous paths.
# Batch ingestion uses #each_split_page so page binaries remain disk-backed.
# #each_part cuts by page range instead, for callers bounded by a byte ceiling.
class PdfPageSplitterService
  class Error < StandardError; end

  Part = Struct.new(:index, :first_page, :last_page, :binary, keyword_init: true) do
    def byte_size  = binary.bytesize
    def page_count = last_page - first_page + 1
  end

  # HexaPDF copies shared resources into every part, so a part re-serialized from
  # an even page split lands above what its page count suggests. Aiming at 80% of
  # the ceiling absorbs that without paying for a second split pass.
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

  # @yield [page_number, binary]
  # @yieldparam page_number [Integer] 1-indexed position in the original document
  # @yieldparam binary      [String]  raw PDF bytes for this single page
  def each_page
    source = HexaPDF::Document.new(io: StringIO.new(@binary))
    total  = source.pages.count

    total.times do |idx|
      target = HexaPDF::Document.new
      target.pages << target.import(source.pages[idx])

      io = StringIO.new("".b)
      target.write(io, validate: false)
      yield(idx + 1, io.string)
    end
  end

  # Writes every self-contained page to a tempfile and yields a SplitPage.
  # The caller owns each yielded tempfile and must call SplitPage#cleanup.
  def each_split_page
    source = HexaPDF::Document.new(io: StringIO.new(@binary))
    total  = source.pages.count

    total.times do |idx|
      target = HexaPDF::Document.new
      target.pages << target.import(source.pages[idx])
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
    range.each { |number| target.pages << target.import(source.pages[number - 1]) }

    io = StringIO.new("".b)
    target.write(io, validate: false)
    io.string
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
