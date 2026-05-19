# frozen_string_literal: true

# Routes a file to the appropriate Claude model and processing mode.
# Deterministic, zero-LLM — all model decisions are made here before any API call.
#
# Result fields:
#   model  [String]          "claude-sonnet-4-6" | "claude-opus-4-7"
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
class FileMultimodalRouter
  MAX_PARALLEL_PAGES = 8

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
    return Result.new(model: BatchChunkingPrompt::MODEL_MULTIMODAL, mode: :image, pages: []) if image?
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
    Result.new(model: BatchChunkingPrompt::MODEL_MULTIMODAL, mode: :pdf_mixed, pages: pages)
  end

  def build_page_infos(image_pages)
    page_infos = []

    PdfPageSplitterService.new(@binary).each_page do |page_num, page_binary|
      has_images = image_pages.include?(page_num)
      model, text_chars, img_ratio = route_page(page_binary, has_images: has_images, page_num: page_num)

      page_infos << PageInfo.new(
        number:           page_num,
        binary:           page_binary,
        has_images:       has_images,
        text_layer_chars: text_chars,
        image_area_ratio: img_ratio,
        model:            model,
        force_opus:       false
      )
    end

    page_infos
  end

  # Determines per-page model with conservative image-to-text downgrade.
  # Always calls PageImageDensityAnalyzer so rasterized slides (no XObjects) are detected.
  # @return [model, text_layer_chars, image_area_ratio]
  def route_page(page_binary, has_images:, page_num:)
    analysis           = PageImageDensityAnalyzer.analyze(page_binary)
    text_chars         = analysis[:text_layer_chars]
    img_ratio          = analysis[:image_area_ratio]
    density_has_images = analysis[:has_images]

    effective_has_images = has_images || density_has_images || img_ratio >= 0.20

    unless effective_has_images
      return [ BatchChunkingPrompt::MODEL_TEXT, text_chars, img_ratio ]
    end

    if text_chars > 500 && img_ratio < 0.20
      Rails.logger.info("PageRouter: p#{page_num} downgraded — image_ratio=#{img_ratio.round(3)}, text_chars=#{text_chars}")
      return [ BatchChunkingPrompt::MODEL_TEXT, text_chars, img_ratio ]
    end

    [ BatchChunkingPrompt::MODEL_MULTIMODAL, text_chars, img_ratio ]
  end
end
