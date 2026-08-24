# frozen_string_literal: true

require "test_helper"

class PdfSplitPeakEstimatorTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # Incompressible bytes from a seeded PRNG, so page sizes are predictable.
  def pdf_with_page_sizes(sizes)
    rng = Random.new(4321)
    doc = HexaPDF::Document.new
    sizes.each { |bytes| doc.pages.add.contents = rng.bytes(bytes) }

    io = StringIO.new("".b)
    doc.write(io, validate: false)
    io.string
  end

  # Sizes are compared with a delta, never with equality: HexaPDF's output shifts
  # by a couple of bytes between document instances, which is noise against a
  # measurement whose unit is the gigabyte.
  def extracted_bytes(binary, number)
    source = HexaPDF::Document.new(io: StringIO.new(binary))
    target = HexaPDF::Document.new
    target.pages << target.import(source.pages[number - 1])
    io = StringIO.new("".b)
    target.write(io, validate: false)
    io.string.bytesize
  end

  # ---------------------------------------------------------------------------
  # Exact measurement
  # ---------------------------------------------------------------------------

  test "peak is the sum of every extracted page, which is what lands in tmp" do
    binary = pdf_with_page_sizes([ 10_000 ] * 4)
    expected = (1..4).sum { |number| extracted_bytes(binary, number) }

    result = PdfSplitPeakEstimator.new(binary).call

    assert_equal 4, result.page_count
    # Not exact equality: HexaPDF renumbers objects as pages are imported, so a
    # page serialised from a fresh document differs from the shared one by a few
    # bytes of xref. The property under test is the sum, not the byte.
    assert_in_delta expected, result.peak_bytes, 64
    assert_not result.sampled?
  end

  test "reports the largest single page, which is what one batch request carries" do
    binary = pdf_with_page_sizes([ 5_000, 5_000, 60_000 ])

    result = PdfSplitPeakEstimator.new(binary).call

    assert_in_delta extracted_bytes(binary, 3), result.largest_page_bytes, 64
    assert_operator result.largest_page_bytes, :>, result.per_page_bytes
  end

  test "peak exceeds the source size because shared resources are copied per page" do
    binary = pdf_with_page_sizes([ 20_000 ] * 6)

    result = PdfSplitPeakEstimator.new(binary).call

    assert_operator result.peak_bytes, :>, binary.bytesize,
                    "per-page extraction should inflate over the source"
  end

  # ---------------------------------------------------------------------------
  # Sampling
  # ---------------------------------------------------------------------------

  test "sampling marks itself as an estimate and extrapolates over every page" do
    binary = pdf_with_page_sizes([ 10_000 ] * 10)

    result = PdfSplitPeakEstimator.new(binary).call(sample: 3)

    assert result.sampled?
    assert_equal 3, result.sampled_pages
    assert_equal 10, result.page_count
    assert_operator result.peak_bytes, :>, 0
  end

  # The reason exact is the default: a few samples cannot see where the weight is.
  test "sampling misses a peak concentrated on unsampled pages" do
    sizes = Array.new(9, 1_000)
    sizes[4] = 400_000
    binary = pdf_with_page_sizes(sizes)

    exact   = PdfSplitPeakEstimator.new(binary).call
    sampled = PdfSplitPeakEstimator.new(binary).call(sample: 2)

    assert_operator sampled.peak_bytes, :<, exact.peak_bytes
  end

  test "a sample at or over the page count degrades to an exact measurement" do
    binary = pdf_with_page_sizes([ 8_000 ] * 3)

    result = PdfSplitPeakEstimator.new(binary).call(sample: 5)

    assert_not result.sampled?
    # Delta, not equality: HexaPDF's output shifts by a couple of bytes between
    # instances, which is noise against a measurement reported in GB.
    assert_in_delta PdfSplitPeakEstimator.new(binary).call.peak_bytes, result.peak_bytes, 64
  end

  # ---------------------------------------------------------------------------
  # Failures and rendering
  # ---------------------------------------------------------------------------

  test "raises on bytes that are not a PDF" do
    error = assert_raises(PdfSplitPeakEstimator::Error) { PdfSplitPeakEstimator.new("nope").call }
    assert_match(/cannot open PDF/, error.message)
  end

  test "renders the peak in GB and says whether it is exact" do
    binary = pdf_with_page_sizes([ 10_000 ] * 3)

    assert_match(/3 pags, pico .* \(exacto\)/, PdfSplitPeakEstimator.new(binary).call.to_s)
    assert_match(/estimado con 2 muestras/, PdfSplitPeakEstimator.new(binary).call(sample: 2).to_s)
  end
end
