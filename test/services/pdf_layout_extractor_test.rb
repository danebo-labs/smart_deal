require "test_helper"

class PdfLayoutExtractorTest < ActiveSupport::TestCase
  FIXTURE_PATH         = Rails.root.join("test/fixtures/files/pdf_layout_extractor_sample.pdf")
  ROTATED_FIXTURE_PATH = Rails.root.join("test/fixtures/files/pdf_layout_extractor_rotated_sample.pdf")

  setup do
    @pages = split_pages(File.binread(FIXTURE_PATH))
  end

  test "extract returns exactly the documented contract keys" do
    result = PdfLayoutExtractor.extract(@pages[0], page_number: 1)

    expected_keys = %i[page_number media_box words lines rects images text_layer_chars image_area_ratio]
    assert_equal expected_keys.sort, result.keys.sort
  end

  test "words group visually contiguous glyphs, including an internal space, and split distinct same-line labels" do
    result = PdfLayoutExtractor.extract(@pages[0], page_number: 1)
    texts  = result[:words].pluck(:text)

    assert_equal [ "CONECTOR AI", "CONECTOR AG", "LIMITADOR" ].sort, texts.sort
  end

  test "lines drop noise segments (|Δx|+|Δy| <= 20) and keep the leader-line polyline" do
    result = PdfLayoutExtractor.extract(@pages[0], page_number: 1)

    assert_equal 2, result[:lines].size
    result[:lines].each do |line|
      manhattan = (line[:from][0] - line[:to][0]).abs + (line[:from][1] - line[:to][1]).abs
      assert manhattan > 20, "expected #{line.inspect} to be kept, but its length is noise-sized"
    end
  end

  test "rects captures the drawn rectangle bbox" do
    result = PdfLayoutExtractor.extract(@pages[0], page_number: 1)

    assert_equal [ { bbox: [ 50, 300, 90, 320 ] } ], result[:rects]
  end

  test "images reuses PageImageDensityAnalyzer's extended output with placement bbox and size_class" do
    result = PdfLayoutExtractor.extract(@pages[0], page_number: 1)

    small = result[:images].find { |i| i[:width] == 100 }
    large = result[:images].find { |i| i[:width] == 2000 }

    assert_equal :small, small[:size_class]
    assert_equal [ 500, 50, 560, 98 ], small[:bbox]
    assert_equal :large, large[:size_class]
    assert_equal [ 10, 50, 210, 150 ], large[:bbox]
  end

  test "coordinate convention: y is bottom-up like HexaPDF, not top-down like pdftotext — fails if inverted" do
    result = PdfLayoutExtractor.extract(@pages[2], page_number: 3)

    top    = result[:words].find { |w| w[:text] == "TOP LABEL" }
    bottom = result[:words].find { |w| w[:text] == "BOTTOM LABEL" }

    assert top.present? && bottom.present?
    assert top[:bbox][1] > bottom[:bbox][1],
      "TOP LABEL (placed near the top of the page) must have a HIGHER y than " \
      "BOTTOM LABEL in a bottom-up coordinate system; got top=#{top[:bbox]} bottom=#{bottom[:bbox]}"
    assert_in_delta 380, top[:bbox][1], 5
    assert_in_delta 20, bottom[:bbox][1], 5
  end

  test "a near-empty divider page still returns a well-formed, mostly empty result" do
    result = PdfLayoutExtractor.extract(@pages[1], page_number: 2)

    assert_equal [], result[:lines]
    assert_equal [], result[:rects]
    assert_equal [], result[:images]
    assert_equal [ "DIVISOR" ], result[:words].pluck(:text)
  end

  test "an unparseable binary returns the empty-but-well-formed result instead of raising" do
    result = PdfLayoutExtractor.extract("not a pdf", page_number: 99)

    assert_equal 99, result[:page_number]
    assert_equal [], result[:words]
    assert_equal [], result[:lines]
    assert_equal [], result[:rects]
    assert_equal [], result[:images]
  end

  test "words from a text matrix rotated 90° are marked rotated: true; horizontal words are not" do
    result = PdfLayoutExtractor.extract(File.binread(ROTATED_FIXTURE_PATH), page_number: 1)

    rotated_texts    = result[:words].select { |w| w[:rotated] }.pluck(:text)
    unrotated_texts  = result[:words].reject { |w| w[:rotated] }.pluck(:text)

    assert_equal [ "P", "3", "5", "B", "E", "S" ].sort, rotated_texts.sort
    assert_equal [ "NORMAL", "CARLOS", "SILVA" ].sort, unrotated_texts.sort
  end

  test "rotated: true is additive — absent, not false, on entries that aren't rotated" do
    result = PdfLayoutExtractor.extract(File.binread(ROTATED_FIXTURE_PATH), page_number: 1)

    normal = result[:words].find { |w| w[:text] == "NORMAL" }
    assert_not normal.key?(:rotated)
  end

  test "no word entry, rotated or not, has an inverted bbox (x0 > x1) or a non-positive height" do
    result = PdfLayoutExtractor.extract(File.binread(ROTATED_FIXTURE_PATH), page_number: 1)

    result[:words].each do |word|
      x0, y0, x1, y1 = word[:bbox]
      assert x0 <= x1, "#{word[:text].inspect} has an inverted bbox on x: #{word[:bbox].inspect}"
      assert y0 < y1, "#{word[:text].inspect} has a non-positive height: #{word[:bbox].inspect}"
    end
  end

  test "a label that changes typeface/size mid-run keeps its word boundary instead of losing the space" do
    result = PdfLayoutExtractor.extract(File.binread(ROTATED_FIXTURE_PATH), page_number: 1)
    texts  = result[:words].pluck(:text)

    assert_includes texts, "CARLOS"
    assert_includes texts, "SILVA"
    assert_not_includes texts, "CARLOSSILVA"
  end

  test "the pre-2b contract keys and order of a non-rotated fixture are unchanged" do
    result = PdfLayoutExtractor.extract(@pages[0], page_number: 1)

    assert_equal [ "CONECTOR AI", "CONECTOR AG", "LIMITADOR" ].sort, result[:words].pluck(:text).sort
    result[:words].each { |word| assert_equal %i[text bbox].sort, word.keys.sort }
  end

  # ⚠️ Fase 4 (contract v8) is precisely the phase that wires this extractor into
  # production, behind IngestionLayoutFlag (off by default) — see
  # docs/rag/plan_conocimiento_visual.md. Pre-Fase-4 this asserted an empty
  # list; now it pins the exact legitimate callers so any OTHER new caller still
  # fails loudly. Fase 5 adds the third one: VisionTopologyExtractor, behind
  # IngestionVisionFlag (also off by default).
  test "only the Fase 4/5 ingestion callers invoke the extractor" do
    invocation = /PdfLayoutExtractor\.(extract|new)\b/
    allowed_callers = %w[manual_batch_ingestion_service.rb single_file_chunking_service.rb vision_topology_extractor.rb]

    callers = Dir.glob(Rails.root.join("app/**/*.rb").to_s).select do |path|
      next false if path.end_with?("pdf_layout_extractor.rb", "page_layout_digest.rb")
      next false if allowed_callers.any? { |name| path.end_with?(name) }

      File.readlines(path).any? { |source_line| !source_line.match?(/\A\s*#/) && source_line.match?(invocation) }
    end

    assert_empty callers, "PdfLayoutExtractor must not be called outside the Fase 4/5 ingestion callers: #{callers}"
  end

  private

  def split_pages(binary)
    pages = []
    PdfPageSplitterService.new(binary).each_page { |_num, page_binary| pages << page_binary }
    pages
  end
end
