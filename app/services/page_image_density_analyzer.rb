# frozen_string_literal: true

# Analyzes a single-page PDF to measure image density relative to page area.
# Uses HexaPDF for structural inspection (no pixel decoding) and PDF::Reader
# for text layer extraction.
#
# Result hash:
#   has_images        [Boolean] - page has at least one Image XObject
#   text_layer_chars  [Integer] - character count of the extracted text layer
#   image_area_ratio  [Float]   - sum of image natural areas / page area (0.0–1.0)
#   images            [Array<Hash>] - one entry per XObject the resource dict
#     declares: { name:, width:, height:, bbox: [x0,y0,x1,y1] or nil, size_class: }
#     bbox is the placed position in page point space (bottom-up), taken from
#     the CTM in effect at its `Do` operator — this is what lets Fase 5
#     (docs/rag/plan_conocimiento_visual.md) crop the right pixels and Fase 3
#     anchor a small photo to its nearest printed label. nil if the resource
#     is declared but never actually painted on the page.
#
# Image area estimation:
#   Natural dimensions at 96 DPI: W_pts = pixel_w * 72/96; H_pts = pixel_h * 72/96
#   Each image area = W_pts * H_pts, clamped to page area.
#   96 DPI chosen as a conservative reference; larger images (full-page scans)
#   will hit the clamp and produce ratio ~1.0 regardless of actual DPI.
class PageImageDensityAnalyzer
  DPI_ASSUMPTION = 96.0
  PTS_PER_INCH   = 72.0
  SCALE          = (PTS_PER_INCH / DPI_ASSUMPTION)**2  # 0.5625 pts² per pixel²

  # Apéndice B (docs/rag/plan_conocimiento_visual.md) measured a wide gap
  # between photographed components (<=~19k px², e.g. 105x183) and full board
  # photos (>=~1.3M px², e.g. 1536x864); 50,000 sits in that gap.
  SMALL_IMAGE_MAX_AREA_PX2 = 50_000

  # @param binary [String] raw single-page PDF bytes
  # @return [Hash] { has_images:, text_layer_chars:, image_area_ratio:, images: }
  def self.analyze(binary)
    new(binary).analyze
  end

  def initialize(binary)
    @binary = binary
  end

  def analyze
    doc       = HexaPDF::Document.new(io: StringIO.new(@binary))
    page      = doc.pages[0]
    return default_result unless page

    page_area = compute_page_area(page)
    img_area, has_images, images = compute_image_area(page, page_area)
    text_chars = count_text_chars

    {
      has_images:       has_images,
      text_layer_chars: text_chars,
      image_area_ratio: page_area.positive? ? (img_area / page_area).clamp(0.0, 1.0) : 0.0,
      images:           images
    }
  rescue StandardError => e
    Rails.logger.warn("PageImageDensityAnalyzer: #{e.class} — #{e.message}")
    default_result
  end

  private

  def default_result
    { has_images: false, text_layer_chars: 0, image_area_ratio: 0.0, images: [] }
  end

  def compute_page_area(page)
    box = page.box(:media)
    box.width.to_f * box.height.to_f
  rescue StandardError
    0.0
  end

  def compute_image_area(page, page_area)
    xobjects = page[:Resources]&.[](:XObject)
    return [ 0.0, false, [] ] unless xobjects.is_a?(HexaPDF::Dictionary)

    placements = capture_image_placements(page)
    total_area = 0.0
    has_images = false
    images     = []

    xobjects.each do |name, xobj|
      next unless xobj.is_a?(HexaPDF::Dictionary) && xobj[:Subtype].to_s == "Image"

      has_images  = true
      w           = xobj[:Width].to_f
      h           = xobj[:Height].to_f

      img_pts_area = if w.positive? && h.positive?
        w * h * SCALE
      else
        page_area * 0.25  # unknown dimensions → conservative 25% estimate
      end

      total_area += [ img_pts_area, page_area ].min
      images << {
        name:       name.to_s,
        width:      w.to_i,
        height:     h.to_i,
        bbox:       placements[name.to_s],
        size_class: small_image?(w.to_i, h.to_i) ? :small : :large
      }
    end

    [ total_area, has_images, images ]
  end

  def small_image?(width, height)
    return true unless width.positive? && height.positive?

    (width * height) < SMALL_IMAGE_MAX_AREA_PX2
  end

  def count_text_chars
    reader = PDF::Reader.new(StringIO.new(@binary))
    reader.pages.sum { |p| p.text.to_s.gsub(/\s+/, "").length }
  rescue StandardError
    0
  end

  # Placement bbox needs the CTM in effect at each `Do`, which the resource
  # dictionary itself never carries (it has no notion of the content
  # stream). A content-stream pass, keyed by XObject name, feeding
  # compute_image_area's own loop above.
  def capture_image_placements(page)
    collector = ImagePlacementCollector.new
    page.process_contents(collector)
    collector.placements
  rescue StandardError => e
    Rails.logger.warn("PageImageDensityAnalyzer: image placement pass failed (#{e.class}) — #{e.message}")
    {}
  end

  class ImagePlacementCollector < HexaPDF::Content::Processor
    attr_reader :placements

    def initialize(*)
      super
      @placements = {}
    end

    def paint_xobject(name)
      xobject = resources.xobject(name)
      record_placement(name, xobject) if xobject.is_a?(HexaPDF::Dictionary) && xobject[:Subtype].to_s == "Image"
      super
    end

    private

    def record_placement(name, _xobject)
      corners = [ [ 0, 0 ], [ 1, 0 ], [ 0, 1 ], [ 1, 1 ] ].map { |x, y| graphics_state.ctm.evaluate(x, y) }
      xs = corners.map(&:first)
      ys = corners.map(&:last)

      @placements[name.to_s] = [ xs.min, ys.min, xs.max, ys.max ]
    end
  end
  private_constant :ImagePlacementCollector
end
