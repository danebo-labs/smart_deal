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
#   words            [Array<Hash>]  { text:, bbox: [x0,y0,x1,y1], rotated: true }
#                    — glyphs grouped by visual adjacency, not stream emission
#                    order. `rotated` is additive: present (and true) only on
#                    entries built from a glyph whose text matrix isn't
#                    axis-aligned (90° rotation); absent otherwise. A rotated
#                    entry's `text` is not reading-order (see Fase 2b/I-13) —
#                    consumers must skip it as an edge endpoint, never quote it
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

  # A glyph's text matrix is axis-aligned iff its "width" edge (lower_left ->
  # lower_right) is horizontal and its "height" edge (lower_left ->
  # upper_left) is vertical. A 90° rotation (either direction) swaps the two
  # axes exactly, so both edges land far outside this tolerance — cheap and
  # direction-agnostic, unlike checking the aggregated bbox for x0 > x1 (only
  # true for one of the two rotation directions; see Gate A §4.2/I-13).
  GLYPH_AXIS_TOLERANCE_PT = 1.0

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

      if gap <= word_gap_tolerance(prev, glyph)
        runs.last << glyph
      else
        runs << [ glyph ]
      end
    end

    runs.map { |glyph_run| word_entry(glyph_run) }
  end

  # The smaller of the two adjacent glyphs' heights, not just `prev`'s: a
  # label that changes typeface/size mid-run (e.g. the page 8 divider,
  # "CARLOS" then a smaller "SILVA") must have its real inter-word gap judged
  # against the smaller glyph, or the larger glyph's height inflates the
  # tolerance enough to swallow a genuine word boundary with no space glyph
  # to fall back on.
  def word_gap_tolerance(prev, current)
    height = [ glyph_height(prev), glyph_height(current) ].min
    [ height * WORD_GAP_RATIO, MIN_WORD_GAP_PT ].max
  end

  def glyph_height(glyph)
    glyph.upper_right[1] - glyph.lower_left[1]
  end

  def rotated_glyph?(glyph)
    width_edge_dy  = glyph.lower_right[1] - glyph.lower_left[1]
    height_edge_dx = glyph.upper_left[0]  - glyph.lower_left[0]
    width_edge_dy.abs > GLYPH_AXIS_TOLERANCE_PT || height_edge_dx.abs > GLYPH_AXIS_TOLERANCE_PT
  end

  # Bbox as the true axis-aligned bounding box over all four corners of every
  # glyph in the run, not just each glyph's lower_left/upper_right. For
  # axis-aligned (non-rotated) glyphs this is identical to the previous
  # lower_left-min/upper_right-max computation. For a rotated glyph, using
  # only those two corners is what produced an inverted or degenerate bbox
  # (Gate A §4.2/I-13) — the other two corners are needed to get x0 <= x1 and
  # y0 <= y1 unconditionally.
  def word_entry(glyph_run)
    corners = glyph_run.flat_map { |g| [ g.lower_left, g.lower_right, g.upper_left, g.upper_right ] }

    entry = {
      text: glyph_run.map(&:string).join,
      bbox: [
        corners.map { |x, _y| x }.min,
        corners.map { |_x, y| y }.min,
        corners.map { |x, _y| x }.max,
        corners.map { |_x, y| y }.max
      ]
    }
    entry[:rotated] = true if glyph_run.any? { |g| rotated_glyph?(g) }
    entry
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
