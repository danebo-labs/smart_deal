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
#   classifying pages in Haiku windows (pages + bytes) to avoid truncation and
#   oversized Anthropic payloads.
#
# @param repeated_texts [Set<String>] texts that appear on >= 3 pages in this document
#   (running headers/footers). Built by the caller from all page texts before filtering.
class PageRelevanceFilter
  HAIKU_MODEL              = "claude-haiku-4-5-20251001"
  HAIKU_TRACKING_MODEL_ID  = "claude-haiku-4-5-20251001-direct"
  HAIKU_MAX_TOKENS         = 64
  HAIKU_BATCH_MAX_TOKENS   = 256
  BATCH_WINDOW_SIZE        = 20
  MAX_WINDOW_BYTES         = 22 * 1024 * 1024
  PER_PAGE_OUTPUT_TOKENS   = 32

  TOC_LINE_FRACTION = 0.30  # ≥30% of lines ending in a page number → ToC
  TOC_MIN_LINES     = 10

  BOILERPLATE_PATTERN = /
    intended\s+audience | how\s+to\s+use\s+this | copyright | all\s+rights\s+reserved |
    prefacio | índice | introducción | preface | table\s+of\s+contents | índice\s+general
  /xi.freeze

  TITLE_PATTERN = /manual|user|guide|guía|manual\s+de/i.freeze

  # Safety/action signal: authorized/qualified personnel, worker coordination,
  # shutdown/lockout/de-energization, or conditional restart after troubleshooting.
  SAFETY_ACTION_SIGNAL_PATTERN = /
    authoriz(?:e[sd]?|ation)?  | qualif(?:ie[sd]?|ication)?   | certif(?:ie[sd]?|ication)   |
    personal\s+autorizado      | personal\s+calificado         |
    coordinat(?:e[sd]?|ion)?   | two[\s\-]person               | multi[\s\-]person            |
    at\s+least\s+two           | al\s+menos\s+dos              |
    shut\s*down                | lock[\s\-]?out                | de[\s\-]?energi[sz]e?        |
    isolat(?:e[sd]?|ion)       | aislamiento                   | bloqueo                      |
    desenergiz                 | re[\s\-]?energi[sz]e?         | reanudar                     |
    restart                    | troubleshoot                  |
    after\s+(?:correc|resolv|troubleshoot)                     |
    después\s+de\s+(?:corregir|solucionar|verificar)
  /xi.freeze

  # Directive/obligation/conditional language — must co-occur with SAFETY_ACTION_SIGNAL_PATTERN.
  SAFETY_DIRECTIVE_PATTERN = /
    \bmust\b | \bshall\b | \brequired?\b | \bimmediately\b | \bonly\s+after\b | \bdo\s+not\b |
    \bdebe\b | \bdeberá\b | \bdeberán\b | \bobligatorio\b | \binmediatamente\b |
    \bsolo\s+después\b | \bno\s+debe\b
  /xi.freeze

  HAIKU_SYSTEM = <<~PROMPT.strip.freeze
    You are a classifier for elevator technician manuals. Return ONLY valid JSON.
    Schema: {"keep":bool,"reason":"<10 words"}
    keep=true  → page has useful technical content (specs, diagrams, troubleshooting, procedures, wiring)
    keep=false → page is boilerplate (index, preface, copyright, blank, table of contents)
  PROMPT

  # Shared PDF text extractor — first page only, safe (returns "" on error).
  def self.extract_page_text(binary)
    reader = PDF::Reader.new(StringIO.new(binary.to_s))
    reader.pages.first&.text.to_s.strip
  rescue StandardError
    ""
  end

  # Returns true when text contains BOTH a safety/action signal and directive language.
  # Only applied to Haiku-dropped pages; structural heuristic drops are never passed here.
  def self.safety_action_guard?(text)
    return false if text.blank?

    text.match?(SAFETY_ACTION_SIGNAL_PATTERN) && text.match?(SAFETY_DIRECTIVE_PATTERN)
  end

  # Shared ToC detection. Accepts full page text; behavior is identical to the original instance method.
  def self.toc?(text)
    lines = text.lines
    return false if lines.count < TOC_MIN_LINES

    trailing = lines.count { |l| l.strip.match?(/\d+\s*$/) }
    trailing.to_f / lines.count >= TOC_LINE_FRACTION
  end

  # Unified routing: call_batch for multi-page docs, per-page filter for single-page.
  # pages must respond to #number and #binary.
  # @return [Hash{Integer => Hash}] page_number => { keep:, reason:, source:, force_opus: }
  # @param correlation_id [String, nil] Gate 9R I0 — document-level "ingest:<sha12>"
  #   so filter calls group with the parse calls of the same upload.
  def self.filter_pages(pages:, filename:, haiku_client: nil, correlation_id: nil)
    return {} if pages.empty?

    if pages.size > 1
      call_batch(pages: pages, filename: filename, haiku_client: haiku_client, correlation_id: correlation_id)
    else
      page   = pages.first
      result = new(page.binary, page_number: page.number, total_pages: 1,
                   filename: filename, haiku_client: haiku_client, correlation_id: correlation_id).call
      { page.number => result }
    end
  end

  # Batch classifier for all pages, split into bounded Haiku windows.
  #
  # @param pages        [Array<#number, #binary>]  page infos with single-page PDF bytes
  # @param filename     [String]                   document filename (for tracking)
  # @param haiku_client [#messages]                injectable Anthropic client (for tests)
  # @return [Hash{Integer => Hash}] page_number => { keep:, reason:, source: :haiku_batch, force_opus: }
  def self.call_batch(pages:, filename:, haiku_client: nil, correlation_id: nil)
    return {} if pages.empty?

    total_pages      = pages.map(&:number).compact.max || pages.size
    windows          = build_batch_windows(pages)
    fallback_windows = []

    results = windows.each_with_object({}) do |window, h|
      filter = BatchFilter.new(
        pages:          window,
        filename:       filename,
        haiku_client:   haiku_client,
        total_pages:    total_pages,
        correlation_id: correlation_id
      )
      h.merge!(filter.call)
      fallback_windows << window_range(window) if filter.fallback?
    end

    log_batch_windows(filename: filename, total_pages: total_pages, windows: windows, fallback_windows: fallback_windows)
    results
  end

  def self.build_batch_windows(pages)
    windows       = []
    current       = []
    current_bytes = 0

    pages.each do |page|
      page_bytes = page.binary.to_s.bytesize

      if current.any? && (current.size >= BATCH_WINDOW_SIZE || current_bytes + page_bytes > MAX_WINDOW_BYTES)
        windows << current
        current       = []
        current_bytes = 0
      end

      current << page
      current_bytes += page_bytes

      if page_bytes > MAX_WINDOW_BYTES
        windows << current
        current       = []
        current_bytes = 0
      end
    end

    windows << current if current.any?
    windows
  end
  private_class_method :build_batch_windows

  def self.window_range(pages)
    numbers = pages.map(&:number).compact
    "#{numbers.min}..#{numbers.max}"
  end
  private_class_method :window_range

  def self.window_bytes(pages)
    pages.sum { |page| page.binary.to_s.bytesize }
  end
  private_class_method :window_bytes

  def self.log_batch_windows(filename:, total_pages:, windows:, fallback_windows:)
    Rails.logger.info(
      JSON.generate(
        event:            "page_relevance_filter_batch_windows",
        filename:         filename,
        total_pages:      total_pages,
        windows_count:    windows.size,
        window_ranges:    windows.map { |window| window_range(window) },
        window_bytes:     windows.map { |window| window_bytes(window) },
        fallback_windows: fallback_windows
      )
    )
  rescue StandardError => e
    Rails.logger.warn("PageRelevanceFilter.call_batch: failed to log window metrics — #{e.message}")
  end
  private_class_method :log_batch_windows

  # @param page_binary    [String]       raw single-page PDF bytes
  # @param page_number    [Integer]      1-indexed position in original document
  # @param total_pages    [Integer]      total page count in document
  # @param filename       [String]       document filename (for tracking)
  # @param repeated_texts [Set<String>]  texts seen >= 3 times across all pages
  # @param haiku_client   [#call]        injectable Anthropic client (for tests)
  def initialize(page_binary, page_number:, total_pages:, filename:,
                 repeated_texts: Set.new, haiku_client: nil, correlation_id: nil)
    @page_binary    = page_binary
    @page_number    = page_number
    @total_pages    = total_pages
    @filename       = filename
    @repeated_texts = repeated_texts
    @haiku_client   = haiku_client
    @correlation_id = correlation_id
  end

  # @return [Hash] { keep: Boolean, reason: String, source: :heuristic | :haiku }
  def call
    density = PageImageDensityAnalyzer.analyze(@page_binary)
    @text   = extract_text

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
    self.class.extract_page_text(@page_binary)
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
    self.class.toc?(@text)
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

    return { keep: true, reason: :safety_action_guard, source: :haiku } if !keep && self.class.safety_action_guard?(@text)

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
      route:                 "page_filter",
      attempt:               1,
      max_tokens:            HAIKU_MAX_TOKENS,
      stop_reason:           (response.respond_to?(:stop_reason) ? response.stop_reason.to_s.presence : nil),
      correlation_id:        @correlation_id,
      source:                "ingestion_parse"
    )
  rescue StandardError => e
    Rails.logger.warn("PageRelevanceFilter: failed to enqueue tracking job — #{e.message}")
  end

  # ─── Batch filter (multi-page PDFs and Office/PPT) ────────────────────────

  # Single Haiku call that classifies one bounded window of rasterized pages.
  # Used exclusively from PageRelevanceFilter.call_batch — do not instantiate directly.
  class BatchFilter
    attr_reader :fallback_reason

    HAIKU_BATCH_SYSTEM = <<~PROMPT.strip.freeze
      You classify rasterized pages (PDF manuals or presentation slides) for elevator technicians.
      Return ONLY raw JSON. Do NOT wrap in markdown fences. Do NOT add any prose.
      Schema: {"pages":[{"page":N,"keep":bool,"reason":"<10 words"},...]}
      keep=false → cover/title page, agenda/index/table of contents, section divider, blank, preface, copyright
      keep=true  → technical diagrams, wiring, photos with components, procedures, specs, data tables
      Be aggressive dropping covers and indexes.
    PROMPT

    def initialize(pages:, filename:, haiku_client:, total_pages:, correlation_id: nil)
      @pages          = pages
      @filename       = filename
      @haiku_client   = haiku_client
      @total_pages    = total_pages
      @correlation_id = correlation_id
    end

    def fallback?
      @fallback_reason.present?
    end

    def call
      client     = @haiku_client || build_client
      max_tokens = dynamic_max_tokens

      response, latency_ms = invoke(client, max_tokens: max_tokens)
      parse_result(response, latency_ms, max_tokens: max_tokens, attempt: 1)
    rescue JSON::ParserError => e
      retry_after_parse_error(client, max_tokens, e)
    rescue StandardError => e
      fallback_result(e)
    end

    private

    def retry_after_parse_error(client, max_tokens, error)
      retry_max_tokens = max_tokens * 2
      Rails.logger.warn(
        "PageRelevanceFilter.call_batch #{@filename} #{window_label} JSON parse failed " \
        "(#{error.class}): #{error.message} — retrying with max_tokens=#{retry_max_tokens}"
      )

      response, latency_ms = invoke(client, max_tokens: retry_max_tokens)
      parse_result(response, latency_ms, max_tokens: retry_max_tokens, attempt: 2)
    rescue JSON::ParserError => e
      fallback_result(e)
    rescue StandardError => e
      fallback_result(e)
    end

    def invoke(client, max_tokens:)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = client.messages.create(
        model:      PageRelevanceFilter::HAIKU_MODEL,
        max_tokens: max_tokens,
        system:     HAIKU_BATCH_SYSTEM,
        messages:   [ { role: "user", content: build_content } ]
      )
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
      [ response, latency_ms ]
    end

    def parse_result(response, latency_ms, max_tokens:, attempt:)
      track_usage(response, latency_ms, max_tokens: max_tokens, attempt: attempt)

      text_block   = response.content.find { |b| b.type.to_s == "text" }
      json_str     = strip_markdown_fences(text_block.text.to_s)
      parsed_pages = JSON.parse(json_str).fetch("pages")

      build_result(parsed_pages)
    end

    def fallback_result(error)
      @fallback_reason = :haiku_batch_error_fallback
      Rails.logger.warn(
        "PageRelevanceFilter.call_batch #{@filename} #{window_label} failed " \
        "(#{error.class}): #{error.message} — keeping window pages"
      )

      @pages.each_with_object({}) do |page, h|
        h[page.number] = { keep: true, reason: :haiku_batch_error_fallback, source: :haiku_batch }
      end
    end

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

    def dynamic_max_tokens
      [
        PageRelevanceFilter::HAIKU_BATCH_MAX_TOKENS,
        64 + @pages.size * PageRelevanceFilter::PER_PAGE_OUTPUT_TOKENS
      ].max
    end

    def build_result(parsed_pages)
      entries = parsed_pages.each_with_object({}) do |entry, h|
        next unless entry.is_a?(Hash)

        page_number = entry["page"].to_i
        h[page_number] = entry if page_number.positive?
      end

      @pages.each_with_object({}) do |page, h|
        entry = entries[page.number]

        if entry
          keep   = entry["keep"] != false
          reason = entry["reason"].to_s.presence&.to_sym || (keep ? :haiku_batch_keep : :haiku_batch_drop)
        else
          keep   = true
          reason = :missing_in_response
        end

        if !keep
          page_text = PageRelevanceFilter.extract_page_text(page.binary)
          if PageRelevanceFilter.safety_action_guard?(page_text)
            keep   = true
            reason = :safety_action_guard
          end
        end

        h[page.number] = {
          keep:       keep,
          reason:     reason,
          source:     :haiku_batch,
          force_opus: keep && scanned_dense?(page.binary)
        }
      end
    end

    def scanned_dense?(binary)
      return false if binary.blank?

      density = PageImageDensityAnalyzer.analyze(binary)
      density[:text_layer_chars].to_i < 100 && density[:image_area_ratio].to_f > 0.7
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

    def track_usage(response, latency_ms, max_tokens:, attempt:)
      usage = response.usage
      TrackBedrockQueryJob.perform_later(
        model_id:              PageRelevanceFilter::HAIKU_TRACKING_MODEL_ID,
        user_query:            "page_filter_batch: #{@filename} #{window_label}/#{@total_pages}",
        latency_ms:            latency_ms,
        input_tokens:          usage.input_tokens.to_i,
        output_tokens:         usage.output_tokens.to_i,
        cache_read_tokens:     usage.respond_to?(:cache_read_input_tokens) && usage.cache_read_input_tokens.to_i > 0 ? usage.cache_read_input_tokens.to_i : nil,
        cache_creation_tokens: usage.respond_to?(:cache_creation_input_tokens) && usage.cache_creation_input_tokens.to_i > 0 ? usage.cache_creation_input_tokens.to_i : nil,
        route:                 "page_filter",
        attempt:               attempt,
        max_tokens:            max_tokens,
        stop_reason:           (response.respond_to?(:stop_reason) ? response.stop_reason.to_s.presence : nil),
        correlation_id:        @correlation_id,
        source:                "ingestion_parse"
      )
    rescue StandardError => e
      Rails.logger.warn("PageRelevanceFilter.call_batch: failed to enqueue tracking job — #{e.message}")
    end

    def window_label
      numbers = @pages.map(&:number).compact
      "#{numbers.min}..#{numbers.max}"
    end
  end
end
