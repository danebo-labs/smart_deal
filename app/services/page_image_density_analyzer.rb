# frozen_string_literal: true

# Analyzes a single-page PDF to measure image density relative to page area.
# Uses HexaPDF for structural inspection (no pixel decoding) and PDF::Reader
# for text layer extraction.
#
# Result hash:
#   has_images        [Boolean] - page has at least one Image XObject
#   text_layer_chars  [Integer] - character count of the extracted text layer
#   image_area_ratio  [Float]   - sum of image natural areas / page area (0.0–1.0)
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

  # @param binary [String] raw single-page PDF bytes
  # @return [Hash] { has_images:, text_layer_chars:, image_area_ratio: }
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
    img_area, has_images = compute_image_area(page, page_area)
    text_chars = count_text_chars

    {
      has_images:       has_images,
      text_layer_chars: text_chars,
      image_area_ratio: page_area.positive? ? (img_area / page_area).clamp(0.0, 1.0) : 0.0
    }
  rescue StandardError => e
    Rails.logger.warn("PageImageDensityAnalyzer: #{e.class} — #{e.message}")
    default_result
  end

  private

  def default_result
    { has_images: false, text_layer_chars: 0, image_area_ratio: 0.0 }
  end

  def compute_page_area(page)
    box = page.box(:media)
    box.width.to_f * box.height.to_f
  rescue StandardError
    0.0
  end

  def compute_image_area(page, page_area)
    xobjects = page[:Resources]&.[](:XObject)
    return [ 0.0, false ] unless xobjects.is_a?(HexaPDF::Dictionary)

    total_area = 0.0
    has_images = false

    xobjects.each do |_name, xobj|
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
    end

    [ total_area, has_images ]
  end

  def count_text_chars
    reader = PDF::Reader.new(StringIO.new(@binary))
    reader.pages.sum { |p| p.text.to_s.gsub(/\s+/, "").length }
  rescue StandardError
    0
  end
end
