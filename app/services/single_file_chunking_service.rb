# frozen_string_literal: true

# Orchestrates the web custom chunking pipeline for a single file.
#
# INVARIANT: one upload (filename + binary in one #call) = one identity.
# Regardless of how many Claude requests are made internally (1 for images/text/PDFs,
# N for pdf_mixed pages), the result is always one ChunkAsset with one canonical
# document_name and one unified aliases list. Today only pdf_mixed issues N>1 calls;
# the two-wave + hint + ChunkMergerService pattern extends to any future multi-call split.
#
# Steps:
#   1. FileMultimodalRouter classifies the file (model + mode).
#   2. Optional Office → PDF conversion.
#   3. PageRelevanceFilter.filter_pages (PDFs only — call_batch for multi-page, per-page for 1-page).
#   4. ClaudeChunkingClient calls — single-shot or two-wave for pdf_mixed:
#        Wave A: anchor page (lowest kept page number) → establishes document_name.
#        Wave B: remaining pages in parallel, receives document_name_hint.
#   5. ChunkMergerService for pdf_mixed.
#   6. BatchResultsParserService writes chunks + sidecars to S3.
#
# Returns the populated ChunkAsset (canonical_name, aliases, chunks_count, etc.).
# Raises on unrecoverable errors — callers (CustomChunkingPipeline) handle fallback.
#
# @param binary        [String]  raw file bytes
# @param content_type  [String]  MIME type
# @param filename      [String]  original filename
# @param s3_key        [String]  S3 key where the original file was uploaded
# @param sha256        [String]  SHA-256 hex digest of the binary
# @param s3_service    [#upload_text] injectable S3 client (for tests)
class SingleFileChunkingService
  def initialize(binary:, content_type:, filename:, s3_key:, sha256:, s3_service: nil, locale: nil,
                 account_id: nil, document_uid: nil)
    @binary         = binary
    @content_type   = content_type
    @filename       = filename
    @s3_key         = s3_key
    @sha256         = sha256
    @locale         = locale
    @account_id     = account_id
    @document_uid   = document_uid
    @s3             = s3_service || S3DocumentsService.new
    @asset          = ChunkAsset.new(filename: filename, sha256: sha256, s3_key: s3_key, content_type: content_type)
    @office_origin  = false
  end

  def call
    classification = FileMultimodalRouter.classify(
      binary:       @binary,
      content_type: @content_type,
      filename:     @filename
    )

    case classification.mode
    when :office       then handle_office
    when :text         then handle_text
    when :image        then handle_image(classification.model)
    when :pdf_text_only then handle_pdf_text_only(classification.model)
    when :pdf_mixed    then handle_pdf_mixed(classification.pages)
    else
      handle_text
    end
  end

  private

  # Gate 9R I0: groups all billable attempts of this upload (and, with the
  # :p<N> suffix, of each page) so the cost matrix can rebuild first/retry/
  # wasted splits per document. Prefix-matches "ingest:<sha12>".
  def correlation_id(page_number = nil)
    base = "ingest:#{@sha256.to_s[0, 12]}"
    page_number ? "#{base}:p#{page_number}" : base
  end

  # ─── Mode handlers ────────────────────────────────────────────────────────

  def handle_text
    content = BatchChunkingPrompt.text_user_content(
      text:     @binary.dup.force_encoding("UTF-8"),
      filename: @filename,
      locale:   @locale
    )
    result = client_for(BatchChunkingPrompt::MODEL_TEXT).call(
      user_content:   content,
      filename:       @filename,
      correlation_id: correlation_id
    )
    parse_and_write(result[:text])
  end

  def handle_image(_router_model)
    route = FieldPhotoDensityGate.decide(
      binary:         @binary,
      content_type:   @content_type,
      filename:       @filename,
      correlation_id: correlation_id
    )

    if route == :sonnet
      model   = BatchChunkingPrompt::MODEL_TEXT
      content = FieldPhotoPrompt.user_content(
        binary:       @binary,
        content_type: @content_type,
        filename:     @filename,
        locale:       @locale
      )
      result   = call_with_page_cap_retry(
        client:       client_for(model, system: FieldPhotoPrompt::SYSTEM_BLOCKS),
        user_content: content
      )
      envelope = FieldPhotoResultsParser.to_envelope(result[:text])
      parse_and_write(envelope.to_json, ingestion_path: "field_photo_v1")
    else
      model   = BatchChunkingPrompt::MODEL_MULTIMODAL
      content = BatchChunkingPrompt.user_content(
        binary:       @binary,
        content_type: @content_type,
        filename:     @filename,
        locale:       @locale
      )
      result = call_with_page_cap_retry(client: client_for(model), user_content: content)
      parse_and_write(result[:text], ingestion_path: "web_v1")
    end
  end

  def handle_pdf_text_only(model)
    content = BatchChunkingPrompt.user_content(
      binary:       @binary,
      content_type: "application/pdf",
      filename:     @filename,
      locale:       @locale
    )
    result = client_for(model).call(
      user_content:   content,
      filename:       @filename,
      correlation_id: correlation_id
    )
    parse_and_write(result[:text])
  end

  def handle_pdf_mixed(pages)
    total      = pages.count
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    filter_results = PageRelevanceFilter.filter_pages(pages: pages, filename: @filename, correlation_id: correlation_id)

    kept_pages = pages.select do |page|
      r = filter_results[page.number] || { keep: true, reason: :missing, source: :fallback }

      if r[:force_opus] && r[:keep]
        page.model      = BatchChunkingPrompt::MODEL_MULTIMODAL
        page.force_opus = true
      end

      Rails.logger.info(
        "PageRelevanceFilter: #{@filename} p#{page.number} " \
        "#{r[:keep] ? 'keep' : 'drop'} (#{r[:reason]}, #{r[:source]})"
      )
      r[:keep]
    end

    if kept_pages.empty?
      if total > PageRelevanceFilter::BATCH_WINDOW_SIZE
        Rails.logger.warn(
          "SingleFileChunkingService: all pages dropped for #{@filename} " \
          "(#{total} pages) — falling back to per-page keep-all"
        )
        page_results = chunk_pages_with_identity_hint(pages, total)
        report       = ChunkMergerService.merge_with_report(page_results)
        log_pdf_mixed_metrics(total: total, parsed_pages: pages, fallback: "per_page_keep_all", started_at: started_at)
        parse_and_write(report[:json])
        @asset.degraded_pages = report[:degraded_pages]
        return @asset
      end

      Rails.logger.warn("SingleFileChunkingService: all pages dropped for #{@filename} — falling back to whole-file parse")
      # Fallback: parse entire PDF as one document rather than silently dropping.
      # Prevents losing documents with technical value (e.g. single-page raster diagrams
      # that heuristics misclassified but Haiku would catch).
      content = BatchChunkingPrompt.user_content(
        binary:       @binary,
        content_type: "application/pdf",
        filename:     @filename,
        locale:       @locale
      )
      result = client_for(BatchChunkingPrompt::MODEL_TEXT).call(
        user_content:   content,
        filename:       @filename,
        correlation_id: correlation_id
      )
      log_pdf_mixed_metrics(total: total, parsed_pages: [], fallback: "whole_file", started_at: started_at)
      return parse_and_write(result[:text])
    end

    page_results = chunk_pages_with_identity_hint(kept_pages, kept_pages.size)
    report       = ChunkMergerService.merge_with_report(page_results)
    log_pdf_mixed_metrics(total: total, parsed_pages: kept_pages, fallback: nil, started_at: started_at)
    parse_and_write(report[:json])
    @asset.degraded_pages = report[:degraded_pages]
    @asset
  end

  def handle_office
    ext        = File.extname(@filename)
    pdf_binary = OfficeToPdfConverter.convert(@binary, extension: ext)

    @office_origin = true

    # Re-classify as PDF now that we have the converted binary
    classification = FileMultimodalRouter.classify(
      binary:       pdf_binary,
      content_type: "application/pdf",
      filename:     @filename
    )

    case classification.mode
    when :pdf_mixed    then handle_pdf_mixed(classification.pages)
    when :pdf_text_only then handle_pdf_text_only_binary(pdf_binary, classification.model)
    else
      handle_pdf_text_only_binary(pdf_binary, BatchChunkingPrompt::MODEL_TEXT)
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────

  # Two-wave approach enforcing the 1 file = 1 identity invariant for pdf_mixed:
  #   Wave A: single call for the anchor page (lowest kept page number) to establish
  #           the document_name for this file.
  #   Wave B: remaining pages in parallel waves, each receiving the hint so Claude
  #           emits the same document_name across all parts of the same file.
  # For single-page inputs, falls through to a direct call (no hint needed).
  def chunk_pages_with_identity_hint(pages, total)
    return [ call_claude_for_page(pages.first, total, document_name_hint: nil, locale: @locale, anchor: true) ] if pages.size == 1

    anchor = pages.min_by(&:number)
    rest   = pages.reject { |p| p.number == anchor.number }

    anchor_result = call_claude_for_page(anchor, total, document_name_hint: nil, locale: @locale, anchor: true)

    hint = begin
      JSON.parse(anchor_result[:text].to_s)["document_name"].to_s.presence
    rescue JSON::ParserError
      nil
    end

    Rails.logger.info("SingleFileChunkingService: pdf_mixed #{@filename} wave-A anchor=p#{anchor.number} hint=#{hint.inspect}")

    rest_results = chunk_pages_parallel(rest, total, document_name_hint: hint)
    [ anchor_result ] + rest_results
  end

  def chunk_pages_parallel(pages, total, document_name_hint: nil)
    pages.each_slice(FileMultimodalRouter::MAX_PARALLEL_PAGES).flat_map do |batch|
      futures = batch.map do |page|
        pg = page
        Concurrent::Promises.future do
          call_claude_for_page(pg, total, document_name_hint: document_name_hint)
        end
      end
      futures.map(&:value!)
    end
  end

  def call_claude_for_page(page, total, document_name_hint:, locale: nil, anchor: false)
    model    = page.model
    page_num = page.number
    content  = BatchChunkingPrompt.page_user_content(
      binary:             page.binary,
      page_number:        page_num,
      total_pages:        total,
      filename:           @filename,
      document_name_hint: document_name_hint,
      locale:             locale,
      anchor:             anchor
    )
    result = call_with_page_cap_retry(
      client:       ClaudeChunkingClient.new(model: model),
      user_content: content,
      page_number:  page_num,
      total_pages:  total
    )
    { page_number: page_num, text: result[:text], usage: result[:usage], model: model, stop_reason: result[:stop_reason] }
  end

  def log_pdf_mixed_metrics(total:, parsed_pages:, fallback:, started_at:)
    parsed_count = parsed_pages.size
    duration_ms  = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

    Rails.logger.info(
      JSON.generate(
        event:       "single_file_chunking_pdf_mixed",
        filename:    @filename,
        total_pages: total,
        kept_pages:  parsed_count,
        dropped_pages: total - parsed_count,
        opus_pages:  parsed_pages.count { |page| page.model == BatchChunkingPrompt::MODEL_MULTIMODAL },
        parse_waves: parse_waves_count(parsed_pages),
        duration_ms: duration_ms,
        fallback:    fallback
      )
    )
  rescue StandardError => e
    Rails.logger.warn("SingleFileChunkingService: failed to log pdf_mixed metrics — #{e.message}")
  end

  def parse_waves_count(pages)
    return 0 if pages.empty?
    return 1 if pages.size == 1

    1 + ((pages.size - 1).fdiv(FileMultimodalRouter::MAX_PARALLEL_PAGES).ceil)
  end

  # Escalation ladder for per-page / per-image calls (O3′: 8k → 16k → 32k).
  # A rung fails when the output is truncated (stop_reason=max_tokens) OR is
  # not parseable JSON — both previously degraded the page to a marker-only
  # placeholder, losing all content (benchmark defect D1). Each failed rung
  # retries at the next cap; only failing pages pay the extra calls.
  PAGE_TOKEN_LADDER = [
    BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
    BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS,
    BatchChunkingPrompt::MAX_TOKENS
  ].freeze

  def call_with_page_cap_retry(client:, user_content:, page_number: nil, total_pages: nil)
    result = nil
    page_label = page_number ? " p#{page_number}" : ""

    PAGE_TOKEN_LADDER.each_with_index do |cap, index|
      result = client.call(
        user_content:   user_content,
        filename:       @filename,
        page_number:    page_number,
        total_pages:    total_pages,
        max_tokens:     cap,
        attempt:        index + 1,
        correlation_id: correlation_id(page_number)
      )

      truncated  = result[:stop_reason] == "max_tokens"
      parseable  = parseable_json?(result[:text])
      return result if !truncated && parseable

      reason = truncated ? "truncated" : "unparseable JSON"
      if index < PAGE_TOKEN_LADDER.size - 1
        Rails.logger.warn(
          "SingleFileChunkingService: #{@filename}#{page_label} #{reason} at " \
          "max_tokens=#{cap} — retrying with #{PAGE_TOKEN_LADDER[index + 1]}"
        )
      else
        Rails.logger.warn(
          "SingleFileChunkingService: #{@filename}#{page_label} still #{reason} at " \
          "max_tokens=#{cap} — page will be marked as degraded"
        )
      end
    end

    result
  end

  # Canonical fence-tolerant check shared with the Batch retry route so the
  # sync ladder and BatchPageRetryService accept exactly the same outputs
  # (mirrors ChunkMergerService#parse_page_result normalization).
  def parseable_json?(text)
    BatchPageRetryService.parseable_json?(text)
  end

  def handle_pdf_text_only_binary(pdf_binary, model)
    content = BatchChunkingPrompt.user_content(
      binary:       pdf_binary,
      content_type: "application/pdf",
      filename:     @filename,
      locale:       @locale
    )
    result = client_for(model).call(
      user_content:   content,
      filename:       @filename,
      correlation_id: correlation_id
    )
    parse_and_write(result[:text])
  end

  def handle_text_binary(binary)
    content = BatchChunkingPrompt.text_user_content(
      text:     binary.dup.force_encoding("UTF-8").scrub,
      filename: @filename,
      locale:   @locale
    )
    result = client_for(BatchChunkingPrompt::MODEL_TEXT).call(
      user_content:   content,
      filename:       @filename,
      correlation_id: correlation_id
    )
    parse_and_write(result[:text])
  end

  def parse_and_write(raw_json, ingestion_path: "web_v1")
    BatchResultsParserService.new(s3_service: @s3).call(
      asset:          @asset,
      raw_json:       raw_json,
      ingestion_path: ingestion_path,
      account_id:     @account_id,
      document_uid:   @document_uid
    )
  end

  def client_for(model, system: BatchChunkingPrompt::SYSTEM_BLOCKS)
    @clients                       ||= {}
    @clients[[ model, system.object_id ]] ||= ClaudeChunkingClient.new(model: model, system: system)
  end
end
