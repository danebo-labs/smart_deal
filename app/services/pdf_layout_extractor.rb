# frozen_string_literal: true

# Extracts printed-label geometry and vector leader lines from a single-page
# PDF, in one HexaPDF::Content::Processor pass. Offline groundwork for
# docs/rag/plan_conocimiento_visual.md (Fase 2) — TopologyEdgeDeriver (Fase 3)
# and the vision tier (Fase 5) consume this contract. Nothing in production
# calls this yet.
#
# Coordinate convention: everything is in HexaPDF's native PDF user space —
# y grows UPWARD from the bottom of the page (bottom-up), same as
# move_to/line_to and glyph boxes. pdftotext -bbox-layout is top-down;
# converting means y_hexapdf = media_box_height - y_pdftotext. This class
# never performs that conversion — it only reports HexaPDF's own coordinates.
#
# Result hash (docs/rag/plan_conocimiento_visual.md, "Contratos de datos"):
#   page_number      [Integer, nil] echoed back from the page_number: kwarg
#   media_box        [Array<Float>] [x0, y0, x1, y1]
#   words            [Array<Hash>]  { text:, bbox: [x0,y0,x1,y1] } — glyphs
#                    grouped by visual adjacency, not stream emission order
#   lines            [Array<Hash>]  { from: [x,y], to: [x,y] } — straight
#                    segments only; noise (<=20pt Manhattan length) dropped
#   rects            [Array<Hash>]  { bbox: [x0,y0,x1,y1] }
#   images           [Array<Hash>]  from PageImageDensityAnalyzer (extended)
#   text_layer_chars [Integer]      from PageImageDensityAnalyzer
#   image_area_ratio [Float]        from PageImageDensityAnalyzer
class PdfLayoutExtractor
  # PDF2.0 s9.4.3: every decoded code point, including the space character,
  # gets its own GlyphBox — so a real inter-word space inside one printed
  # label leaves ~0 gap between glyphs, while two visually separate labels
  # sit many points apart. A ratio of glyph height, not an absolute point
  # value, so the tolerance scales with font size.
  WORD_GAP_RATIO      = 0.6
  MIN_WORD_GAP_PT     = 1.0
  LINE_Y_TOLERANCE_PT = 2.0

  # Same cut as the plan's `lines` contract: |Δx| + |Δy| <= 20 is
  # boundary/underline noise, not a leader line.
  LINE_NOISE_MAX_MANHATTAN_PT = 20

  # @param page_binary [String] raw single-page PDF bytes
  # @param page_number [Integer, nil] original 1-indexed page number, echoed back
  # @return [Hash]
  def self.extract(page_binary, page_number: nil)
    new(page_binary, page_number: page_number).extract
  end

  def initialize(page_binary, page_number: nil)
    @page_binary = page_binary
    @page_number = page_number
  end

  def extract
    doc  = HexaPDF::Document.new(io: StringIO.new(@page_binary))
    page = doc.pages[0]
    return empty_result unless page

    collector = LayoutCollector.new
    page.process_contents(collector)

    density = PageImageDensityAnalyzer.analyze(@page_binary)
    box     = page.box(:media)

    {
      page_number:      @page_number,
      media_box:        [ box.left, box.bottom, box.right, box.top ],
      words:            build_words(collector.glyphs),
      lines:            build_lines(collector.segments),
      rects:            collector.rects.map { |bbox| { bbox: bbox } },
      images:           density[:images],
      text_layer_chars: density[:text_layer_chars],
      image_area_ratio: density[:image_area_ratio]
    }
  rescue StandardError => e
    Rails.logger.warn("PdfLayoutExtractor: #{e.class} — #{e.message}")
    empty_result
  end

  private

  def empty_result
    {
      page_number: @page_number, media_box: nil, words: [], lines: [], rects: [],
      images: [], text_layer_chars: 0, image_area_ratio: 0.0
    }
  end

  def build_words(glyphs)
    return [] if glyphs.empty?

    cluster_lines(glyphs).flat_map { |line_glyphs| merge_into_words(line_glyphs) }
  end

  # Groups glyphs into text lines by baseline-y proximity — a pass over
  # geometry, independent of which Tj/TJ operator produced each glyph.
  def cluster_lines(glyphs)
    sorted = glyphs.sort_by { |g| -g.lower_left[1] }
    lines  = [ [ sorted.first ] ]

    sorted.drop(1).each do |glyph|
      if (lines.last.last.lower_left[1] - glyph.lower_left[1]).abs <= LINE_Y_TOLERANCE_PT
        lines.last << glyph
      else
        lines << [ glyph ]
      end
    end

    lines
  end

  # Within a line, merges glyphs whose horizontal gap is small relative to
  # glyph height into one word — this is what keeps "CONECTOR AI" (one
  # printed label with an internal space) as a single entry while still
  # splitting it from an unrelated label many points further along the
  # same line, e.g. "CONECTOR AG".
  def merge_into_words(line_glyphs)
    sorted = line_glyphs.sort_by { |g| g.lower_left[0] }
    runs   = [ [ sorted.first ] ]

    sorted.drop(1).each do |glyph|
      prev = runs.last.last
      gap  = glyph.lower_left[0] - prev.lower_right[0]

      if gap <= word_gap_tolerance(prev)
        runs.last << glyph
      else
        runs << [ glyph ]
      end
    end

    runs.map { |glyph_run| word_entry(glyph_run) }
  end

  def word_gap_tolerance(glyph)
    height = glyph.upper_right[1] - glyph.lower_left[1]
    [ height * WORD_GAP_RATIO, MIN_WORD_GAP_PT ].max
  end

  def word_entry(glyph_run)
    {
      text: glyph_run.map(&:string).join,
      bbox: [
        glyph_run.map { |g| g.lower_left[0] }.min,
        glyph_run.map { |g| g.lower_left[1] }.min,
        glyph_run.map { |g| g.upper_right[0] }.max,
        glyph_run.map { |g| g.upper_right[1] }.max
      ]
    }
  end

  def build_lines(segments)
    segments
      .select { |from, to| ((from[0] - to[0]).abs + (from[1] - to[1]).abs) > LINE_NOISE_MAX_MANHATTAN_PT }
      .map { |from, to| { from: from, to: to } }
  end

  # Single content-stream pass: glyph boxes (words), straight segments
  # (lines), and rectangles (rects). Curves are legitimate PDF content but no
  # leader line in the source documents is drawn as a Bézier — traced by
  # HexaPDF's operator dispatch, but deliberately not emitted here.
  class LayoutCollector < HexaPDF::Content::Processor
    attr_reader :glyphs, :segments, :rects

    def initialize(*)
      super
      @glyphs   = []
      @segments = []
      @rects    = []
      @cursor   = nil
    end

    def show_text(str)
      collect_glyphs(str)
    end

    def show_text_with_positioning(arr)
      collect_glyphs(arr)
    end

    def move_to(x, y)
      @cursor = [ x, y ]
    end

    def line_to(x, y)
      @segments << [ @cursor, [ x, y ] ] if @cursor
      @cursor = [ x, y ]
    end

    def append_rectangle(x, y, w, h)
      @rects << [ x, y, x + w, y + h ]
    end

    def curve_to(*); end

    private

    def collect_glyphs(data)
      decode_text_with_positioning(data).each { |glyph_box| @glyphs << glyph_box }
    end
  end
  private_constant :LayoutCollector
end
