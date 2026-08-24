# frozen_string_literal: true

# Measures the disk a PDF costs while the batch route splits it into single pages.
#
# Bulk ingestion materialises every page of a document as its own PDF before
# filtering (BulkCostV2RequestBuilder#collect_pages), so source bytes are not a
# predictor of disk; pages × per-page size is the only one. This is the check
# 04_ingesta lacked: it died at page 383 with "No space left on device" after the
# page filter had already been billed.
#
# ⚠️ The historical numbers this class was written for (10.4 MB per page, 5.61 GB
# for a 515-page KONE scan, ~350x inflation) measured a defect, not a property of
# the PDF: per-page extraction dragged the whole article thread through /B. With
# PdfPageSplitterService::WHOLE_DOCUMENT_ONLY_KEYS pruned that same manual peaks
# at 17.9 MB, so any budget recorded before that fix is stale by ~355x. Re-measure
# rather than trusting a stored figure.
class PdfSplitPeakEstimator
  class Error < StandardError; end

  Result = Struct.new(:page_count, :peak_bytes, :largest_page_bytes, :sampled_pages, keyword_init: true) do
    def sampled? = !sampled_pages.nil?

    def per_page_bytes = page_count.zero? ? 0 : peak_bytes / page_count

    def to_s
      format(
        "%d pags, pico %.2f GB%s, pagina mayor %.1f MB, media %.1f KB/pag",
        page_count,
        peak_bytes / 1e9,
        sampled? ? " (estimado con #{sampled_pages} muestras)" : " (exacto)",
        largest_page_bytes / 1e6,
        per_page_bytes / 1024.0
      )
    end
  end

  def initialize(binary)
    @binary = binary
  end

  # @param sample [Integer, nil] measure only this many evenly spread pages and
  #   extrapolate. Default nil, meaning measure every page, because sampling is
  #   unreliable here: the inflation concentrates on image-heavy pages, so on the
  #   manual above three samples predicted 4.45 GB and 6.64 GB against an exact
  #   5.61 GB. Sample only to triage a large corpus, never to clear a tight budget.
  def call(sample: nil)
    document = load_document
    total    = document.pages.count
    raise Error, "PDF has no pages" if total.zero?

    numbers = sample ? sampled_numbers(total, sample) : (1..total).to_a
    sizes   = numbers.map { |number| extracted_page_bytes(document, number) }

    # A sample that ends up covering every page is not an estimate any more, so
    # it is not labelled as one.
    measured_all = sizes.size == total

    Result.new(
      page_count:         total,
      peak_bytes:         measured_all ? sizes.sum : (sizes.sum / sizes.size) * total,
      largest_page_bytes: sizes.max,
      sampled_pages:      measured_all ? nil : sizes.size
    )
  end

  private

  def load_document
    HexaPDF::Document.new(io: StringIO.new(@binary))
  rescue StandardError => e
    raise Error, "cannot open PDF: #{e.class} — #{e.message}"
  end

  def sampled_numbers(total, sample)
    count = sample.to_i.clamp(1, total)
    return (1..total).to_a if count == total

    step = (total - 1) / (count - 1).to_f
    (0...count).map { |i| (1 + (i * step)).round.clamp(1, total) }.uniq
  end

  # Serialises the page exactly as #each_split_page would, which is what makes
  # the number comparable to what lands in /tmp — including the prune, so this
  # estimator cannot gate a ZIP on bytes the splitter no longer writes.
  def extracted_page_bytes(document, number)
    page = document.pages[number - 1]
    PdfPageSplitterService::WHOLE_DOCUMENT_ONLY_KEYS.each { |key| page.delete(key) }

    target = HexaPDF::Document.new
    target.pages << target.import(page)

    io = StringIO.new("".b)
    target.write(io, validate: false)
    io.string.bytesize
  end
end
