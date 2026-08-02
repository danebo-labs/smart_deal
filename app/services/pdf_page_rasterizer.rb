# frozen_string_literal: true

# Rasterizes a single-page PDF into the image payloads the T2 vision tier sends
# to Claude (docs/rag/plan_conocimiento_visual.md, Fase 5): one full-page raster
# plus one crop per small graphic, each framed together with the printed label
# that names it.
#
# INGESTION ONLY. Nothing here may be reached from a runtime query path — the
# visual enrichment invariant (docs/RAG_SEGURIDADES_BENCHMARK.md:109-115) is
# that vision runs when the document is ingested, never when it is asked about.
#
# Renders through `Vips::Image.pdfload_buffer` (libvips' poppler loader). No new
# dependency: `ruby-vips` is already in the Gemfile via `image_processing`, and
# `Dockerfile:19` installs Debian's `libvips`, which pulls in `libpoppler-glib8`
# and therefore ships `VipsForeignLoadPdfBuffer` (verified in I-34).
#
# COORDINATES
#
# Everything crossing this class's public API is in HexaPDF page space — y grows
# UPWARD from the bottom of the media box, the same convention
# PdfLayoutExtractor and TopologyEdgeDeriver use. Rasters are y-DOWN. The flip
# lives in #pixel_box and nowhere else.
#
# WHY THESE DPIs (measured on `SEGURIDADES 1.1-1.pdf`, not chosen by feel)
#
#   PAGE_DPI = 150   The Gate A and Gate A-bis human ground truth — the 153
#                    hand-read relations of §5 and the one-by-one visual review
#                    of all 19 T1 edges — was read off `pdftoppm -r 150 -png`
#                    renders (script/gate_a/zoom.py; tmp/pdfs/holdout-page-*.png
#                    are 2000x1125 for a 960x540 pt page). Gate B scores T2
#                    against exactly that ground truth, so T2 gets the same
#                    pixels the humans had: no handicap, and no evidence any
#                    more resolves anything. Checked by eye on page 17 — the
#                    canonical page whose terminal numbering lives inside the
#                    raster (I-15) — every borne (32/78/77/76/185/184/…) is
#                    legible from 110 DPI up, so 150 carries margin.
#
#   CROP_DPI = 200   Measured native placement density of the 1,646 small images
#                    in the document: p50 198.7, p90 202.6 DPI (pixel width of
#                    the XObject over the width in inches it is painted at).
#                    Below ~200 the crop throws away pixels the PDF actually
#                    carries; above it, only the vector overlay gains and the
#                    photograph is upsampled. 200 is the top of the measured
#                    distribution, not a round number.
#
#   MAX_LONG_EDGE_PX Bounds cost by pixels rather than by page size, so an
#                    unusually large media box degrades DPI instead of billing a
#                    huge image. 2000 px is the long edge of the same 150 DPI
#                    ground-truth render.
class PdfPageRasterizer
  class RasterError < StandardError; end

  PAGE_DPI         = 150
  CROP_DPI         = 200
  MAX_LONG_EDGE_PX = 2_000

  # A crop frames the union of the graphic and its label, so this is breathing
  # room around that union, not a guess at how far the label might be: one text
  # line of this document (7-9 pt glyphs, Apéndice D) so nothing is clipped
  # flush against the frame.
  CROP_MARGIN_PT = 8.0

  # Below this a "crop" is a handful of pixels — nothing a model can read, and
  # the XObject is a rule or a bullet rather than a component.
  MIN_CROP_EDGE_PT = 6.0

  JPEG_QUALITY = 80

  # @!attribute data       [String] base64 JPEG, ready for an image content block
  # @!attribute media_type [String] always "image/jpeg"
  # @!attribute width      [Integer] rendered pixels
  # @!attribute height     [Integer] rendered pixels
  # @!attribute dpi        [Integer] effective DPI after the long-edge clamp
  Raster = Struct.new(:data, :media_type, :width, :height, :dpi, :bytes, keyword_init: true)

  # @param page_binary [String] raw single-page PDF bytes
  # @param media_box   [Array<Float>, nil] [x0, y0, x1, y1] from
  #   PdfLayoutExtractor. Absent (or malformed) means "assume the render covers
  #   the whole page from the origin", which is what poppler does anyway when
  #   crop box == media box; supplying it is what keeps crops correct when the
  #   origin is not (0, 0).
  def initialize(page_binary, media_box: nil)
    @page_binary = page_binary
    @media_box   = normalize_media_box(media_box)
    @renders     = {}
  end

  # Full page at PAGE_DPI (clamped by MAX_LONG_EDGE_PX).
  # @return [Raster]
  def page(dpi: PAGE_DPI)
    encode(render(dpi), dpi)
  end

  # One crop framing `bbox` — pass the union of a graphic and the label that
  # names it (TopologyEdgeDeriver.label_for_image) so the model never has to
  # guess which printed name belongs to the part it is looking at.
  #
  # @param bbox [Array<Float>] [x0, y0, x1, y1] in HexaPDF page space
  # @return [Raster, nil] nil when the box is degenerate or off-page
  def crop(bbox, dpi: CROP_DPI)
    box = Array(bbox).map(&:to_f)
    return nil unless box.size == 4
    return nil if (box[2] - box[0]).abs < MIN_CROP_EDGE_PT || (box[3] - box[1]).abs < MIN_CROP_EDGE_PT

    image = render(dpi)
    left, top, width, height = pixel_box(box, image, dpi)
    return nil if width < 1 || height < 1

    encode(image.crop(left, top, width, height), dpi)
  end

  # Union of two page-space bboxes — the graphic and its label. Public because
  # it is the caller's job to decide WHICH label, and this class's job to know
  # how a crop is framed.
  # @return [Array<Float>]
  def self.union_bbox(first, second)
    a = Array(first).map(&:to_f)
    b = Array(second).map(&:to_f)
    return a if b.size != 4
    return b if a.size != 4

    [ [ a[0], b[0] ].min, [ a[1], b[1] ].min, [ a[2], b[2] ].max, [ a[3], b[3] ].max ]
  end

  private

  def normalize_media_box(media_box)
    box = Array(media_box).map(&:to_f)
    return nil unless box.size == 4 && box[2] > box[0] && box[3] > box[1]

    box
  end

  # One poppler render per DPI, reused across every crop of the page — 15-24
  # crops is the measured norm for a content page, and re-decoding the PDF for
  # each of them would dominate the page's ingestion time.
  def render(dpi)
    @renders[dpi] ||= begin
      image = Vips::Image.pdfload_buffer(@page_binary, page: 0, dpi: effective_dpi(dpi))
      image.bands > 3 ? image.flatten(background: 255) : image
    rescue Vips::Error, NoMethodError => e
      raise RasterError, "pdfload_buffer failed at #{dpi} DPI: #{e.message}"
    end
  end

  # Degrades DPI (never the other way) so an oversized media box cannot bill a
  # raster larger than the ground-truth render.
  def effective_dpi(dpi)
    return dpi unless @media_box

    long_edge_pt = [ @media_box[2] - @media_box[0], @media_box[3] - @media_box[1] ].max
    return dpi if long_edge_pt <= 0

    ceiling = (MAX_LONG_EDGE_PX * 72.0 / long_edge_pt).floor
    [ dpi, ceiling ].min.clamp(1, dpi)
  end

  # HexaPDF page space (y up, origin at the media box corner) -> raster pixels
  # (y down, origin top-left), clamped to the rendered image.
  def pixel_box(box, image, dpi)
    origin_x, origin_y = @media_box ? [ @media_box[0], @media_box[1] ] : [ 0.0, 0.0 ]
    scale_x = @media_box ? image.width / (@media_box[2] - @media_box[0]) : effective_dpi(dpi) / 72.0
    scale_y = @media_box ? image.height / (@media_box[3] - @media_box[1]) : effective_dpi(dpi) / 72.0

    margin = CROP_MARGIN_PT
    left   = ((box[0] - margin - origin_x) * scale_x).floor.clamp(0, image.width - 1)
    right  = ((box[2] + margin - origin_x) * scale_x).ceil.clamp(1, image.width)
    top_pt = @media_box ? @media_box[3] : (image.height / scale_y)
    top    = ((top_pt - box[3] - margin) * scale_y).floor.clamp(0, image.height - 1)
    bottom = ((top_pt - box[1] + margin) * scale_y).ceil.clamp(1, image.height)

    [ left, top, right - left, bottom - top ]
  end

  # ImageCompressionService is the existing byte bound for every image this
  # codebase hands to a model or to Bedrock (3.75 MB); it no-ops below that, so
  # it costs nothing on the normal path and is the only thing standing between a
  # pathological page and an oversized request.
  def encode(image, dpi)
    blob    = image.write_to_buffer(".jpg[Q=#{JPEG_QUALITY}]")
    bounded = ImageCompressionService.compress(Base64.strict_encode64(blob), "image/jpeg")
    # Over the bound that service resizes as well as recompresses, so the
    # reported dimensions have to come from what it returned, not from what was
    # rendered. Never hit on this path in practice (a 2000x1125 page at Q=80 is
    # ~1 MB) — measured and reported rather than assumed away.
    resized = bounded[:binary].bytesize != blob.bytesize
    width, height = resized ? decoded_dimensions(bounded[:binary], image) : [ image.width, image.height ]

    Raster.new(
      data:       bounded[:data],
      media_type: bounded[:media_type],
      width:      width,
      height:     height,
      dpi:        effective_dpi(dpi),
      bytes:      bounded[:binary].bytesize
    )
  rescue Vips::Error => e
    raise RasterError, "JPEG encode failed: #{e.message}"
  end

  def decoded_dimensions(binary, fallback)
    decoded = Vips::Image.new_from_buffer(binary, "")
    [ decoded.width, decoded.height ]
  rescue Vips::Error
    [ fallback.width, fallback.height ]
  end
end
