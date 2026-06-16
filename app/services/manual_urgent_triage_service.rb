# frozen_string_literal: true

# Parses a few automatically selected pages from a long web/chat PDF while the
# complete manual continues through Anthropic Batch. This is the E3b urgent path:
# bounded direct calls, partial KB sync, and explicit partial metadata.
class ManualUrgentTriageService
  class NoPagesSelected < StandardError; end

  PAGE_TOKEN_LADDER = SingleFileChunkingService::PAGE_TOKEN_LADDER
  TRACKING_PREFIX = "web_urgent"
  PROCESSING_SCOPE = "urgent_pages"

  def initialize(selector: nil, s3_service: nil, bulk_sync_service: nil,
                 bedrock_job: BedrockIngestionJob, client_factory: nil)
    @selector = selector || ManualUrgentPageSelector.new
    @s3 = s3_service || S3DocumentsService.new
    @bulk_sync = bulk_sync_service || BulkKbSyncService.new
    @bedrock_job = bedrock_job
    @client_factory = client_factory || ->(model) { ClaudeChunkingClient.new(model: model) }
  end

  # @return [Hash] selected_pages:, chunks_s3_prefix:, canonical_name:, aliases:
  def call(binary:, filename:, sha256:, s3_key:, query:, kb_doc_id: nil,
           conv_session_id: nil, locale: nil, web_manual_batch_id: nil)
    pages = @selector.select(
      binary: binary,
      filename: filename,
      query: query,
      max_pages: urgent_page_limit
    )
    raise NoPagesSelected, "No urgent pages selected for #{filename}" if pages.empty?

    document_total_pages = [ total_pages(binary), pages.map(&:number).max.to_i ].max
    page_results = parse_pages_with_identity_hint(
      pages,
      filename: filename,
      sha256: sha256,
      locale: locale,
      document_total_pages: document_total_pages
    )
    report = ChunkMergerService.merge_with_report(page_results)

    asset = ChunkAsset.new(filename: filename, sha256: sha256, s3_key: s3_key, content_type: "application/pdf")
    chunk_asset = BatchResultsParserService.new(s3_service: @s3).call(
      asset: asset,
      raw_json: report[:json],
      ingestion_path: BatchResultsParserService::MANUAL_BATCH_INGESTION_PATH
    )
    chunk_asset.degraded_pages = report[:degraded_pages]

    sync_result = @bulk_sync.sync!(uploaded_filenames: [ filename ], locale: locale)
    raise "Bedrock sync did not start for urgent pages" if sync_result.blank?

    metadata = build_metadata(
      filename: filename,
      chunk_asset: chunk_asset,
      selected_pages: pages.map(&:number),
      total_pages: document_total_pages,
      web_manual_batch_id: web_manual_batch_id
    )

    @bedrock_job.perform_later(
      sync_result[:job_id],
      [ filename ],
      kb_id: sync_result[:kb_id],
      data_source_id: sync_result[:data_source_id],
      conv_session_id: conv_session_id,
      kb_document_ids: [ kb_doc_id ].compact,
      web_v1_metadata: [ metadata ],
      locale: locale
    )

    metadata.merge(
      "canonical_name" => chunk_asset.canonical_name.to_s,
      "aliases" => Array(chunk_asset.aliases)
    )
  end

  private

  def urgent_page_limit
    value = ENV.fetch("WEB_URGENT_TRIAGE_PAGES", ManualUrgentPageSelector::DEFAULT_MAX_PAGES).to_i
    value.positive? ? value : ManualUrgentPageSelector::DEFAULT_MAX_PAGES
  end

  def parse_pages_with_identity_hint(pages, filename:, sha256:, locale:, document_total_pages:)
    if pages.size == 1
      return [ call_claude_for_page(
        pages.first,
        filename: filename,
        sha256: sha256,
        locale: locale,
        document_total_pages: document_total_pages,
        anchor: true
      ) ]
    end

    anchor = pages.first
    anchor_result = call_claude_for_page(
      anchor,
      filename: filename,
      sha256: sha256,
      locale: locale,
      document_total_pages: document_total_pages,
      anchor: true
    )
    hint = document_name_from(anchor_result[:text])

    rest = pages.drop(1).map do |page|
      call_claude_for_page(
        page,
        filename: filename,
        sha256: sha256,
        document_name_hint: hint,
        document_total_pages: document_total_pages,
        anchor: false
      )
    end

    [ anchor_result ] + rest
  end

  def call_claude_for_page(page, filename:, sha256:, document_total_pages:, locale: nil, document_name_hint: nil, anchor: false)
    user_content = BatchChunkingPrompt.page_user_content(
      binary: page.binary,
      page_number: page.number,
      total_pages: document_total_pages,
      filename: filename,
      document_name_hint: document_name_hint,
      locale: locale,
      anchor: anchor
    )

    result = call_with_page_cap_retry(
      client: @client_factory.call(page.model),
      user_content: user_content,
      filename: filename,
      page_number: page.number,
      total_pages: document_total_pages,
      sha256: sha256
    )

    {
      page_number: page.number,
      text: result[:text],
      usage: result[:usage],
      model: page.model,
      stop_reason: result[:stop_reason]
    }
  end

  def call_with_page_cap_retry(client:, user_content:, filename:, page_number:, total_pages:, sha256:)
    result = nil

    PAGE_TOKEN_LADDER.each_with_index do |cap, index|
      result = client.call(
        user_content: user_content,
        filename: filename,
        page_number: page_number,
        total_pages: total_pages,
        max_tokens: cap,
        tracking_prefix: TRACKING_PREFIX,
        route: "sync",
        attempt: index + 1,
        correlation_id: "ingest:#{sha256.to_s[0, 12]}:urgent:p#{page_number}"
      )

      healthy = result[:stop_reason] != "max_tokens" && BatchPageRetryService.parseable_json?(result[:text])
      return result if healthy

      Rails.logger.warn(
        "ManualUrgentTriageService: #{filename} p#{page_number} " \
        "unhealthy at max_tokens=#{cap} — #{index < PAGE_TOKEN_LADDER.size - 1 ? 'retrying' : 'degrading'}"
      )
    end

    result
  end

  def document_name_from(text)
    LlmJsonParser.parse(text).fetch("document_name", nil).to_s.presence
  rescue JSON::ParserError
    nil
  end

  def total_pages(binary)
    PdfPageSplitterService.new(binary).page_count
  end

  def build_metadata(filename:, chunk_asset:, selected_pages:, total_pages:, web_manual_batch_id:)
    {
      "filename" => filename,
      "canonical_name" => chunk_asset.canonical_name.to_s,
      "aliases" => Array(chunk_asset.aliases),
      "summary" => chunk_asset.summary.to_s.presence,
      "companion_offer" => chunk_asset.companion_offer.to_s.presence,
      "chunks_s3_prefix" => chunk_asset.chunks_s3_prefix.to_s.presence,
      "partial_pages" => Array(chunk_asset.degraded_pages),
      "processing_scope" => PROCESSING_SCOPE,
      "selected_pages" => selected_pages,
      "total_pages" => total_pages,
      "web_manual_batch_id" => web_manual_batch_id
    }
  end
end
