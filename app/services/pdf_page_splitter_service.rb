# frozen_string_literal: true

require "tempfile"

# Splits a multi-page PDF into individual single-page PDFs using HexaPDF.
# Legacy #each_page yields in-memory binaries for short synchronous paths.
# Batch ingestion uses #each_split_page so page binaries remain disk-backed.
class PdfPageSplitterService
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

  private

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
