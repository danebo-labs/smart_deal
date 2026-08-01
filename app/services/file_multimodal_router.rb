# frozen_string_literal: true

# Routes a file to the appropriate Claude model and processing mode.
# Deterministic, zero-LLM — all model decisions are made here before any API call.
#
# Result fields:
#   model  [String]          "claude-sonnet-4-6" | "claude-opus-4-8"
#   mode   [Symbol]          :text | :image | :pdf_text_only | :pdf_mixed | :office
#   pages  [Array<PageInfo>] per-page routing detail for :pdf_mixed; empty otherwise
#
# PageInfo fields:
#   number           [Integer] 1-indexed, preserves original page numbering (gaps allowed after drops)
#   binary           [String]  single-page PDF bytes
#   has_images       [Boolean]
#   text_layer_chars [Integer]
#   image_area_ratio [Float]   0.0–1.0
#   model            [String]  per-page model decision after downgrade evaluation
#   force_opus       [Boolean] true when PageRelevanceFilter flagged :scanned_image
#
# Fase 1 visual triage (docs/rag/plan_conocimiento_visual.md), behind
# IngestionVisualTriageFlag — flag off leaves routing byte-identical to before:
#   The scanned-page gate (text_chars < 100 && image_ratio > 0.7) always applied
#   here is preserved unconditionally. A second, independent trigger escalates a
#   page with a typed title but a traced schematic underneath it — long vector
#   segments plus several small photographed components — subject to an explicit
#   budget (DocumentClassProfile::DEFAULT_MAX_OPUS_PAGE_FRACTION of total pages,
#   highest complexity first). See hallazgo I-02 for why this reads geometry
#   itself instead of depending on the Fase 2 PdfLayoutExtractor contract.
class FileMultimodalRouter
  MAX_PARALLEL_PAGES = 8

  # Apéndice C census criterion (SEGURIDADES, 98 pages): pages with >= 10 long
  # segments AND >= 3 small images are the ones geometry alone identifies as
  # traced schematics (80/98 pages matched). Not tuned "a ojo" — lifted directly
  # from the verified census.
  LONG_SEGMENT_MIN_COUNT     = 10
  SMALL_IMAGE_MIN_COUNT      = 3
  # |Δx| + |Δy| <= 20pt is noise (borders/underlines) — same cut Fase 2's
  # PdfLayoutExtractor contract documents for `lines`.
  LONG_SEGMENT_MIN_LENGTH_PT = 20
  # No pixel threshold for "small" is fixed anywhere in the plan. Apéndice B's
  # measured examples show a wide gap between photographed components (<=~19k
  # px^2, e.g. 105x183) and full board photos (>=~1.3M px^2, e.g. 1536x864);
  # 50,000 sits in that gap. Fase 2 should own the authoritative size_class cut.
  SMALL_IMAGE_MAX_AREA_PX2   = 50_000

  TEXT_MIME_TYPES = %w[
    text/plain text/markdown text/csv text/html text/xml
    application/json application/x-ndjson
  ].freeze

  IMAGE_MIME_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze

  OFFICE_EXTENSIONS = %w[.doc .docx .xls .xlsx .ppt .pptx .odt .ods .odp].freeze

  OFFICE_MIME_TYPES = %w[
    application/msword
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.ms-powerpoint
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.oasis.opendocument.text
    application/vnd.oasis.opendocument.spreadsheet
    application/vnd.oasis.opendocument.presentation
  ].freeze

  Result   = Struct.new(:model, :mode, :pages, keyword_init: true)
  PageInfo = Struct.new(:number, :binary, :has_images, :text_layer_chars, :image_area_ratio, :model, :force_opus, keyword_init: true)

  # @param binary       [String] raw file bytes
  # @param content_type [String] MIME type
  # @param filename     [String] original filename (used for extension-based detection)
  # @return [Result]
  def self.classify(binary:, content_type:, filename:)
    new(binary: binary, content_type: content_type, filename: filename).classify
  end

  def initialize(binary:, content_type:, filename:)
    @binary       = binary
    @content_type = content_type.to_s.split(";").first.strip.downcase
    @filename     = filename.to_s
  end

  def classify
    return classify_office if office?
    return Result.new(model: BatchChunkingPrompt::MODEL_TEXT, mode: :text, pages: []) if text?
    return Result.new(model: BatchChunkingPrompt::MODEL_TEXT, mode: :image, pages: []) if image?
    return classify_pdf if pdf?

    # Unknown MIME — treat as text (safe default)
    Result.new(model: BatchChunkingPrompt::MODEL_TEXT, mode: :text, pages: [])
  end

  private

  def text?  = TEXT_MIME_TYPES.include?(@content_type)
  def image? = IMAGE_MIME_TYPES.include?(@content_type)
  def pdf?   = @content_type == "application/pdf"

  # After OfficeToPdfConverter, callers re-classify with application/pdf bytes but the
  # original filename may still be .pptx — must not treat that as :office again.
  def office?
    return false if pdf?

    OFFICE_MIME_TYPES.include?(@content_type) ||
      OFFICE_EXTENSIONS.include?(File.extname(@filename).downcase)
  end

  def classify_office
    Result.new(model: BatchChunkingPrompt::MODEL_TEXT, mode: :office, pages: [])
  end

  def classify_pdf
    total_pages = PdfPageSplitterService.new(@binary).page_count

    if total_pages <= 1
      return Result.new(model: BatchChunkingPrompt::MODEL_TEXT, mode: :pdf_text_only, pages: [])
    end

    image_pages = PdfImageDetector.image_pages(@binary)
    pages = build_page_infos(image_pages)
    Result.new(model: BatchChunkingPrompt::MODEL_TEXT, mode: :pdf_mixed, pages: pages)
  end

  def build_page_infos(image_pages)
    page_infos           = []
    geometry_candidates  = []
    triage_on            = IngestionVisualTriageFlag.enabled?

    PdfPageSplitterService.new(@binary).each_page do |page_num, page_binary|
      has_images = image_pages.include?(page_num)
      model, text_chars, img_ratio = route_page(page_binary, has_images: has_images, page_num: page_num)

      page_info = PageInfo.new(
        number:           page_num,
        binary:           page_binary,
        has_images:       has_images,
        text_layer_chars: text_chars,
        image_area_ratio: img_ratio,
        model:            model,
        force_opus:       false
      )
      page_infos << page_info

      # Scanned-dense pages already escalated above; the geometric trigger only
      # applies to pages the existing gate left on Sonnet.
      next unless triage_on && model == BatchChunkingPrompt::MODEL_TEXT

      geometry = geometry_signal(page_binary)
      next unless geometry[:long_segments] >= LONG_SEGMENT_MIN_COUNT &&
                  geometry[:small_images] >= SMALL_IMAGE_MIN_COUNT

      geometry_candidates << { page_info: page_info, complexity_score: geometry[:long_segments] + geometry[:small_images] }
    end

    apply_geometric_escalation(page_infos, geometry_candidates) if geometry_candidates.any?

    page_infos
  end

  def apply_geometric_escalation(page_infos, geometry_candidates)
    escalated = DocumentClassProfile.select_escalation_pages(
      candidates: geometry_candidates.map { |c| { page_number: c[:page_info].number, complexity_score: c[:complexity_score] } },
      total_pages: page_infos.size,
      max_opus_page_fraction: DocumentClassProfile::DEFAULT_MAX_OPUS_PAGE_FRACTION
    )

    geometry_candidates.each do |c|
      next unless escalated.include?(c[:page_info].number)

      Rails.logger.info("PageRouter: p#{c[:page_info].number} visual_complexity_geometric → Opus (score=#{c[:complexity_score]})")
      c[:page_info].model = BatchChunkingPrompt::MODEL_MULTIMODAL
    end
  end

  # Lightweight, private polyline/image counter for the geometric trigger above —
  # NOT the Fase 2 PdfLayoutExtractor contract (no bboxes, no words, no media_box).
  # Only answers "does this page look like a traced schematic": long vector
  # segments plus several small photographed parts. See hallazgo I-02.
  class SegmentCollector < HexaPDF::Content::Processor
    attr_reader :segments

    def initialize(*)
      super
      @segments = []
      @cursor   = nil
    end

    def move_to(x, y)
      @cursor = [ x, y ]
    end

    def line_to(x, y)
      @segments << [ @cursor, [ x, y ] ] if @cursor
      @cursor = [ x, y ]
    end
  end
  private_constant :SegmentCollector

  def geometry_signal(page_binary)
    doc  = HexaPDF::Document.new(io: StringIO.new(page_binary))
    page = doc.pages[0]
    return { long_segments: 0, small_images: 0 } unless page

    collector = SegmentCollector.new
    page.process_contents(collector)
    long_segments = collector.segments.count do |from, to|
      (from[0] - to[0]).abs + (from[1] - to[1]).abs > LONG_SEGMENT_MIN_LENGTH_PT
    end

    { long_segments: long_segments, small_images: count_small_images(page) }
  rescue StandardError => e
    Rails.logger.warn("FileMultimodalRouter: geometry_signal failed (#{e.class}) — #{e.message}")
    { long_segments: 0, small_images: 0 }
  end

  def count_small_images(page)
    xobjects = page[:Resources]&.[](:XObject)
    return 0 unless xobjects.is_a?(HexaPDF::Dictionary)

    count = 0
    xobjects.each do |_name, xobj|
      next unless xobj.is_a?(HexaPDF::Dictionary) && xobj[:Subtype].to_s == "Image"

      w = xobj[:Width].to_f
      h = xobj[:Height].to_f
      count += 1 if w.positive? && h.positive? && (w * h) < SMALL_IMAGE_MAX_AREA_PX2
    end
    count
  end

  # Determines per-page model. Default is Sonnet (MODEL_TEXT); Opus only for
  # fully scanned/rasterized pages (text_layer_chars < 100 AND image_area_ratio > 0.7).
  # Always calls PageImageDensityAnalyzer so rasterized slides (no XObjects) are detected.
  # @return [model, text_layer_chars, image_area_ratio]
  def route_page(page_binary, has_images:, page_num:)
    analysis           = PageImageDensityAnalyzer.analyze(page_binary)
    text_chars         = analysis[:text_layer_chars]
    img_ratio          = analysis[:image_area_ratio]

    if text_chars < 100 && img_ratio > 0.7
      Rails.logger.info("PageRouter: p#{page_num} scanned_dense → Opus (text_chars=#{text_chars}, image_ratio=#{img_ratio.round(3)})")
      return [ BatchChunkingPrompt::MODEL_MULTIMODAL, text_chars, img_ratio ]
    end

    [ BatchChunkingPrompt::MODEL_TEXT, text_chars, img_ratio ]
  end
end
