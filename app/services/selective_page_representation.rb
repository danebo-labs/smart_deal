# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# Chooses the PDF bytes the batch page filter sends to Haiku.
#
# A page with a real text layer is classified from a temporary image-only copy.
# An adequate scan is the original page, not a second raster. Guards,
# scanned_dense?, and the parse builders keep reading the original: the copy
# exists only inside the Haiku request and is deleted before this method
# returns. The cut is the same one as PageRelevanceFilter.scanned_dense?.
class SelectivePageRepresentation
  TEXT_CHARS = 100
  DENSE_RATIO = 0.7
  DPI = 200
  CONCURRENCY = 2

  Decision = Struct.new(:representation, :kind, keyword_init: true) do
    def visual?
      representation == :visual
    end
  end

  # binary and text stay on the original page. byte_size and
  # classification_binary are the bytes that enter the Haiku window.
  class PayloadPage
    attr_reader :number, :original, :kind, :representation

    def initialize(original, decision, visual_path: nil)
      @original = original
      @number = original.number
      @kind = decision.kind
      @representation = decision.representation
      @visual_path = visual_path
    end

    delegate :binary, to: :original

    def text
      if original.respond_to?(:text) && !original.text.nil?
        original.text.to_s
      else
        PageRelevanceFilter.extract_page_text(binary)
      end
    end

    def classification_binary
      @classification_binary ||= @visual_path ? File.binread(@visual_path) : binary
    end

    def byte_size
      @byte_size ||= classification_binary.bytesize
    end
  end

  class Renderer
    def render(page, directory)
      PdfPageRasterizer.allow_pdf_loader!
      png = nil
      image = Vips::Image.pdfload_buffer(page.binary, page: 0, dpi: DPI)
      image = image.flatten(background: 255) if image.bands > 3
      width = image.width
      height = image.height
      png = File.join(directory, format("visual-%04d.png", page.number))
      pdf_path = File.join(directory, format("visual-%04d.pdf", page.number))
      image.write_to_file(png)
      image = nil

      width_pt = width * 72.0 / DPI
      height_pt = height * 72.0 / DPI
      document = HexaPDF::Document.new
      pdf_page = document.pages.add
      box = [ 0, 0, width_pt, height_pt ]
      pdf_page[:MediaBox] = box
      pdf_page[:CropBox] = box
      pdf_page[:Rotate] = 0
      placed = document.images.add(png)
      pdf_page.canvas.image(placed, at: [ 0, 0 ], width: width_pt, height: height_pt)
      document.write(pdf_path, validate: false)
      pdf_path
    ensure
      File.unlink(png) if png && File.exist?(png)
    end
  end

  def self.decide(binary)
    return Decision.new(representation: :original, kind: :analysis_error) if binary.blank?

    analysis = PageImageDensityAnalyzer.analyze(binary)
    chars = analysis[:text_layer_chars].to_i
    ratio = analysis[:image_area_ratio].to_f
    if chars.zero? && !analysis[:has_images] && !pdf_readable?(binary)
      return Decision.new(representation: :original, kind: :analysis_error)
    end
    if chars < TEXT_CHARS && ratio > DENSE_RATIO
      return Decision.new(representation: :original, kind: :adequate_scan)
    end
    if chars >= TEXT_CHARS
      kind = analysis[:has_images] ? :mixed_text : :text
      return Decision.new(representation: :visual, kind: kind)
    end
    return Decision.new(representation: :visual, kind: :short_text) if chars.positive?

    Decision.new(representation: :original, kind: :no_text)
  rescue StandardError
    Decision.new(representation: :original, kind: :analysis_error)
  end

  def self.pdf_readable?(binary)
    PDF::Reader.new(StringIO.new(binary.to_s)).page_count.positive?
  rescue StandardError
    false
  end
  private_class_method :pdf_readable?

  def self.call(pages)
    session = new(pages)
    session.prepare
    yield session.payload_pages, session.failures
  ensure
    session&.cleanup!
  end

  def initialize(pages)
    @pages = pages
    @payload_pages = []
    @failures = []
    @inflight = {}
    @cleaned = false
  end

  attr_reader :payload_pages, :failures

  def prepare
    @directory = Dir.mktmpdir("danebo-haiku55-page-")
    @renderer = Thread.current[:selective_page_renderer] || Renderer.new
    decisions = @pages.map { |page| self.class.decide(page.binary) }
    ready = {}
    index = 0

    while index < @pages.size || @inflight.any? || ready.any?
      while @inflight.size < CONCURRENCY && index < @pages.size
        page = @pages[index]
        decision = decisions[index]
        if decision.visual?
          @inflight[index] = Thread.new(page, decision) { |item, choice| render_visual(item, choice) }
        else
          ready[index] = [ :ok, PayloadPage.new(page, decision) ]
        end
        index += 1
      end

      needed = (@inflight.keys + ready.keys).min
      outcome = ready.key?(needed) ? ready.delete(needed) : @inflight.delete(needed).value
      if outcome.first == :ok
        @payload_pages << outcome.last
      else
        @failures << outcome.last
      end
    end

    Rails.logger.info(JSON.generate(
      event: "selective_page_representation",
      pages: @pages.size,
      visual: @payload_pages.count { |page| page.representation == :visual },
      original: @payload_pages.count { |page| page.representation == :original },
      render_failures: @failures.size
    ))
  end

  def cleanup!
    return if @cleaned

    @inflight.each_value do |thread|
      thread.join
    rescue StandardError
      nil
    end
    @inflight.clear
    FileUtils.remove_entry(@directory) if @directory && File.exist?(@directory)
    @cleaned = true
  end

  private

  def render_visual(page, decision)
    path = @renderer.render(page, @directory)
    [ :ok, PayloadPage.new(page, decision, visual_path: path) ]
  rescue StandardError => e
    Rails.logger.warn("SelectivePageRepresentation page #{page.number}: #{e.class}")
    [ :error, page ]
  end
end
