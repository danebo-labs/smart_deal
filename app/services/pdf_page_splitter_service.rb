# frozen_string_literal: true

# Splits a multi-page PDF into individual single-page PDFs using HexaPDF.
# Yields each page as (page_number [Integer, 1-indexed], binary [String]).
# The single-page PDFs are self-contained with all referenced resources imported.
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
end
