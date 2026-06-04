# frozen_string_literal: true

# Decides whether a single extracted PDF page is worth chunking.
# Applied per-page inside SingleFileChunkingService before any expensive API calls.
#
# Returns: { keep: Boolean, reason: String, source: :heuristic | :haiku }
#
# Pipeline (cascade, first match wins):
#   1. Heuristic rules (zero LLM) — deterministic fast path
#   2. Haiku 4.5 gating call — for ambiguous pages (50–800 chars, no clear signal)
#
# Special case — cover_slide (runs first in apply_heuristics, p1 only):
#   page_number == 1 AND text_layer_chars < 10 AND image_area_ratio > 0.7 AND text < 50 → drop.
#   Catches fully-rasterized covers in native PDFs. Office-origin files use call_batch instead.
#
# Special case — scanned_image (fallback after heuristics):
#   text_layer_chars < 100 AND image_area_ratio > 0.7 → keep (force Opus 4.7, skip Haiku)
#
# Batch mode (multi-page docs — PDF native or Office/PPT):
#   PageRelevanceFilter.filter_pages routes to call_batch for pages.size > 1,
#   classifying all N pages in a single Haiku call (avoids scanned_image short-circuit
#   that would keep covers/indexes).
#
# @param repeated_texts [Set<String>] texts that appear on >= 3 pages in this document
#   (running headers/footers). Built by the caller from all page texts before filtering.
class PageRelevanceFilter
  HAIKU_MODEL              = "claude-haiku-4-5-20251001"
  HAIKU_TRACKING_MODEL_ID  = "claude-haiku-4-5-20251001-direct"
  HAIKU_MAX_TOKENS         = 64
  HAIKU_BATCH_MAX_TOKENS   = 256

  TOC_LINE_FRACTION = 0.30  # ≥30% of lines ending in a page number → ToC
  TOC_MIN_LINES     = 10

  BOILERPLATE_PATTERN = /
    intended\s+audience | how\s+to\s+use\s+this | copyright | all\s+rights\s+reserved |
    prefacio | índice | introducción | preface | table\s+of\s+contents | índice\s+general
  /xi.freeze

  TITLE_PATTERN = /manual|user|guide|guía|manual\s+de/i.freeze

  HAIKU_SYSTEM = <<~PROMPT.strip.freeze
    You are a classifier for elevator technician manuals. Return ONLY valid JSON.
    Schema: {"keep":bool,"reason":"<10 words"}
    keep=true  → page has useful technical content (specs, diagrams, troubleshooting, procedures, wiring)
    keep=false → page is boilerplate (index, preface, copyright, blank, table of contents)
  PROMPT

  # Unified routing: call_batch for multi-page docs, per-page filter for single-page.
  # pages must respond to #number and #binary.
  # @return [Hash{Integer => Hash}] page_number => { keep:, reason:, source:, force_opus: }
  def self.filter_pages(pages:, filename:, haiku_client: nil)
    return {} if pages.empty?

    if pages.size > 1
      call_batch(pages: pages, filename: filename, haiku_client: haiku_client)
    else
      page   = pages.first
      result = new(page.binary, page_number: page.number, total_pages: 1,
                   filename: filename, haiku_client: haiku_client).call
      { page.number => result }
    end
  end

  # Batch classifier for all pages in a single Haiku call.
  #
  # @param pages        [Array<#number, #binary>]  page infos with single-page PDF bytes
  # @param filename     [String]                   document filename (for tracking)
  # @param haiku_client [#messages]                injectable Anthropic client (for tests)
  # @return [Hash{Integer => Hash}] page_number => { keep:, reason:, source: :haiku_batch, force_opus: }
  def self.call_batch(pages:, filename:, haiku_client: nil)
    return {} if pages.empty?

    BatchFilter.new(pages: pages, filename: filename, haiku_client: haiku_client).call
  end

  # @param page_binary    [String]       raw single-page PDF bytes
  # @param page_number    [Integer]      1-indexed position in original document
  # @param total_pages    [Integer]      total page count in document
  # @param filename       [String]       document filename (for tracking)
  # @param repeated_texts [Set<String>]  texts seen >= 3 times across all pages
  # @param haiku_client   [#call]        injectable Anthropic client (for tests)
  def initialize(page_binary, page_number:, total_pages:, filename:,
                 repeated_texts: Set.new, haiku_client: nil)
    @page_binary    = page_binary
    @page_number    = page_number
    @total_pages    = total_pages
    @filename       = filename
    @repeated_texts = repeated_texts
    @haiku_client   = haiku_client
  end

  # @return [Hash] { keep: Boolean, reason: String, source: :heuristic | :haiku }
  def call
    density = PageImageDensityAnalyzer.analyze(@page_binary)
    @text   = extract_text
    @lines  = @text.lines

    heuristic_result = apply_heuristics(density)
    return heuristic_result if heuristic_result

    # Scanned image: text layer thin but image covers most of page → keep, force Opus
    if density[:text_layer_chars] < 100 && density[:image_area_ratio] > 0.7
      Rails.logger.info("PageRelevanceFilter p#{@page_number}: scanned_image (chars=#{density[:text_layer_chars]}, ratio=#{density[:image_area_ratio].round(3)})")
      return { keep: true, reason: :scanned_image, source: :heuristic, force_opus: true }
    end

    # High-confidence content: long text or large meaningful image
    if @text.length > 800 || (density[:has_images] && density[:image_area_ratio] >= 0.25)
      return { keep: true, reason: :high_confidence_content, source: :heuristic }
    end

    # Ambiguous — delegate to Haiku gating
    haiku_gate(density)
  end

  private

  def extract_text
    reader = PDF::Reader.new(StringIO.new(@page_binary))
    reader.pages.first&.text.to_s.strip
  rescue StandardError
    ""
  end

  def apply_heuristics(density)
    # Rasterized cover (p1 only): truly zero text layer + high image ratio — drop without pattern match.
    # Conservative threshold (< 10) avoids intercepting scanned technical pages that have thin but
    # non-zero text detection (those still fall through to scanned_image → keep + Opus).
    # Office-origin files use call_batch instead and never reach this path.
    # CRITICAL: only applies when total_pages > 1 — a 1-page PDF cannot be a "cover" (nothing behind it).
    # Single-page raster diagrams/schematics fall through to scanned_image → keep + force_opus.
    if @total_pages > 1 && @page_number == 1 && density[:text_layer_chars] < 10 && density[:image_area_ratio] > 0.7 && @text.length < 50
      return { keep: false, reason: :cover_slide, source: :heuristic }
    end

    # Title page: check first for page 1 so short cover pages are classified correctly
    # before the blank rule catches them (covers are often < 50 chars).
    if @page_number == 1 && @text.length < 400 && @text.match?(TITLE_PATTERN)
      return { keep: false, reason: :title_page, source: :heuristic }
    end

    # Boilerplate: check before blank so known phrases on short pages are classified correctly
    if @text.length < 600 && @text.match?(BOILERPLATE_PATTERN)
      return { keep: false, reason: :boilerplate, source: :heuristic }
    end

    # Running header/footer artifact: text identical to >= 3 other pages
    # Guard: text.length > 20 avoids false positives on scanned blank pages
    if @text.length > 20 && @repeated_texts.include?(@text)
      return { keep: false, reason: :repeated_artifact, source: :heuristic }
    end

    # Blank: almost no text and no images (after named patterns so short meaningful text wins)
    if @text.length < 50 && !density[:has_images]
      return { keep: false, reason: :blank, source: :heuristic }
    end

    # Table of contents: many lines with trailing page numbers
    if toc?
      return { keep: false, reason: :table_of_contents, source: :heuristic }
    end

    nil
  end

  def toc?
    return false if @lines.count < TOC_MIN_LINES

    trailing_digit_lines = @lines.count { |l| l.strip.match?(/\d+\s*$/) }
    trailing_digit_lines.to_f / @lines.count >= TOC_LINE_FRACTION
  end

  def haiku_gate(density)
    client     = @haiku_client || build_haiku_client
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    content = [
      {
        type: "document",
        source: {
          type:       "base64",
          media_type: "application/pdf",
          data:       Base64.strict_encode64(@page_binary)
        }
      },
      { type: "text", text: "Is this page useful technical content or boilerplate?" }
    ]

    response = client.messages.create(
      model:      HAIKU_MODEL,
      max_tokens: HAIKU_MAX_TOKENS,
      system:     HAIKU_SYSTEM,
      messages:   [ { role: "user", content: content } ]
    )

    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
    text_block = response.content.find { |b| b.type.to_s == "text" }
    parsed     = JSON.parse(text_block.text.to_s)

    keep   = parsed["keep"] != false
    reason = parsed["reason"].to_s.presence || (keep ? "haiku_keep" : "haiku_drop")

    track_haiku_usage(response, latency_ms)

    { keep: keep, reason: reason.to_sym, source: :haiku }
  rescue StandardError => e
    Rails.logger.warn("PageRelevanceFilter Haiku gate p#{@page_number} failed (#{e.class}): #{e.message} — defaulting keep=true")
    { keep: true, reason: :haiku_error_fallback, source: :haiku }
  end

  def build_haiku_client
    api_key = ENV.fetch("ANTHROPIC_API_KEY", nil).presence ||
              Rails.application.credentials.dig(:anthropic, :api_key)
    Anthropic::Client.new(api_key: api_key)
  end

  def track_haiku_usage(response, latency_ms)
    usage = response.usage
    TrackBedrockQueryJob.perform_later(
      model_id:              HAIKU_TRACKING_MODEL_ID,
      user_query:            "page_filter: #{@filename} p#{@page_number}/#{@total_pages}",
      latency_ms:            latency_ms,
      input_tokens:          usage.input_tokens.to_i,
      output_tokens:         usage.output_tokens.to_i,
      cache_read_tokens:     usage.respond_to?(:cache_read_input_tokens) && usage.cache_read_input_tokens.to_i > 0 ? usage.cache_read_input_tokens.to_i : nil,
      cache_creation_tokens: usage.respond_to?(:cache_creation_input_tokens) && usage.cache_creation_input_tokens.to_i > 0 ? usage.cache_creation_input_tokens.to_i : nil,
      source:                "ingestion_parse"
    )
  rescue StandardError => e
    Rails.logger.warn("PageRelevanceFilter: failed to enqueue tracking job — #{e.message}")
  end

  # ─── Batch filter (multi-page PDFs and Office/PPT) ────────────────────────

  # Single Haiku call that classifies all N rasterized pages at once.
  # Used exclusively from PageRelevanceFilter.call_batch — do not instantiate directly.
  class BatchFilter
    HAIKU_BATCH_SYSTEM = <<~PROMPT.strip.freeze
      You classify rasterized pages (PDF manuals or presentation slides) for elevator technicians.
      Return ONLY raw JSON. Do NOT wrap in markdown fences. Do NOT add any prose.
      Schema: {"pages":[{"page":N,"keep":bool,"reason":"<10 words"},...]}
      keep=false → cover/title page, agenda/index/table of contents, section divider, blank, preface, copyright
      keep=true  → technical diagrams, wiring, photos with components, procedures, specs, data tables
      Be aggressive dropping covers and indexes.
    PROMPT

    def initialize(pages:, filename:, haiku_client:)
      @pages        = pages
      @filename     = filename
      @haiku_client = haiku_client
    end

    def call
      client     = @haiku_client || build_client
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = client.messages.create(
        model:      PageRelevanceFilter::HAIKU_MODEL,
        max_tokens: PageRelevanceFilter::HAIKU_BATCH_MAX_TOKENS,
        system:     HAIKU_BATCH_SYSTEM,
        messages:   [ { role: "user", content: build_content } ]
      )

      latency_ms   = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
      text_block   = response.content.find { |b| b.type.to_s == "text" }
      json_str     = strip_markdown_fences(text_block.text.to_s)
      parsed_pages = JSON.parse(json_str).fetch("pages")
      result       = build_result(parsed_pages)

      track_usage(response, latency_ms)
      result
    rescue StandardError => e
      Rails.logger.warn("PageRelevanceFilter.call_batch #{@filename} failed (#{e.class}): #{e.message} — keeping all pages")
      @pages.each_with_object({}) do |page, h|
        h[page.number] = { keep: true, reason: :haiku_batch_error_fallback, source: :haiku_batch }
      end
    end

    private

    def build_content
      content = []
      @pages.each do |page|
        content << { type: "text", text: "Page #{page.number}:" }
        content << {
          type:   "document",
          source: {
            type:       "base64",
            media_type: "application/pdf",
            data:       Base64.strict_encode64(page.binary)
          }
        }
      end
      content << { type: "text", text: "Classify each slide. Return ONLY the JSON object." }
      content
    end

    def build_result(parsed_pages)
      result = @pages.each_with_object({}) do |page, h|
        h[page.number] = { keep: true, reason: :missing_in_response, source: :haiku_batch, force_opus: false }
      end

      parsed_pages.each do |entry|
        num    = entry["page"].to_i
        keep   = entry["keep"] != false
        reason = entry["reason"].to_s.presence&.to_sym || (keep ? :haiku_batch_keep : :haiku_batch_drop)
        result[num] = { keep: keep, reason: reason, source: :haiku_batch, force_opus: keep }
      end

      result
    end

    def strip_markdown_fences(text)
      text.strip
          .sub(/\A```(?:json)?\s*/i, "")
          .sub(/```\s*\z/, "")
          .strip
    end

    def build_client
      api_key = ENV.fetch("ANTHROPIC_API_KEY", nil).presence ||
                Rails.application.credentials.dig(:anthropic, :api_key)
      Anthropic::Client.new(api_key: api_key)
    end

    def track_usage(response, latency_ms)
      usage = response.usage
      n     = @pages.size
      TrackBedrockQueryJob.perform_later(
        model_id:              PageRelevanceFilter::HAIKU_TRACKING_MODEL_ID,
        user_query:            "page_filter_batch: #{@filename} 1..#{n}/#{n}",
        latency_ms:            latency_ms,
        input_tokens:          usage.input_tokens.to_i,
        output_tokens:         usage.output_tokens.to_i,
        cache_read_tokens:     usage.respond_to?(:cache_read_input_tokens) && usage.cache_read_input_tokens.to_i > 0 ? usage.cache_read_input_tokens.to_i : nil,
        cache_creation_tokens: usage.respond_to?(:cache_creation_input_tokens) && usage.cache_creation_input_tokens.to_i > 0 ? usage.cache_creation_input_tokens.to_i : nil,
        source:                "ingestion_parse"
      )
    rescue StandardError => e
      Rails.logger.warn("PageRelevanceFilter.call_batch: failed to enqueue tracking job — #{e.message}")
    end
  end
end
