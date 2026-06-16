# frozen_string_literal: true

# Orchestrates the async Batch API ingestion path for a single multi-page PDF
# manual uploaded from web/chat. Bulk ZIP PDFs use BatchIngestionService +
# BulkCostV2RequestBuilder.
#
# Contrast with BatchIngestionService (ZIP bulk path, whole-file Opus, no filter):
#   - This service splits the PDF per-page, applies PageRelevanceFilter per page,
#     and submits one Anthropic Batch request per kept page using Sonnet (MODEL_TEXT).
#   - Opus only for pages where PageRelevanceFilter flags force_opus.
#
# Returns { batch_id:, page_customs: { page_num => custom_id }, kept_pages: [page_num, ...] }
# so downstream IngestManualBatchResultsJob can match results by custom_id.
#
# Pricing: Anthropic Batch API ~50% off vs sync; tracked with user_query
# "web_batch: filename pN/M" for web long-manual uploads.
# in IngestManualBatchResultsJob (not here — we don't have tokens until results arrive).
class ManualBatchIngestionService
  CUSTOM_ID_PAGE_PATTERN = "%s_p%d"

  PageProxy = Struct.new(:number, :binary)
  private_constant :PageProxy

  # @param batch_client [ClaudeBatchClient, nil] injectable for tests
  def initialize(batch_client: nil)
    @batch_client = batch_client || ClaudeBatchClient.new
  end

  # @param binary   [String]       raw PDF bytes
  # @param filename [String]       original filename
  # @param sha256   [String]       full 64-char SHA-256 hex
  # @param s3_key   [String]       S3 key for the uploaded file
  # @param locale   [String, nil]  ISO 639-1 (forwarded to anchor page)
  # @return [Hash] { batch_id: String, page_customs: Hash, kept_pages: Array<Integer> }
  def submit!(binary:, filename:, sha256:, s3_key:, locale: nil)
    splitter   = PdfPageSplitterService.new(binary)
    total_pages = splitter.page_count

    return empty_result if total_pages.zero?

    pages = collect_page_infos(splitter, total_pages)
    return empty_result if pages.empty?

    filter_results = build_filter_results(pages, filename, sha256)
    kept_pages     = apply_filters(pages, filter_results)

    return empty_result if kept_pages.empty?

    document_name_hint_slot = { value: nil }
    requests = build_batch_requests(kept_pages, filename, sha256, locale, document_name_hint_slot)

    batch = @batch_client.submit_batch(requests: requests)

    page_customs = kept_pages.each_with_object({}) do |page, h|
      h[page[:number]] = custom_id_for(sha256, page[:number])
    end

    Rails.logger.info(
      "ManualBatchIngestionService: #{filename} submitted #{kept_pages.size}/#{total_pages} pages " \
      "batch_id=#{batch.id}"
    )

    {
      batch_id:    batch.id,
      page_customs: page_customs,
      kept_pages:  kept_pages.pluck(:number),
      total_pages: total_pages,
      filename:    filename,
      sha256:      sha256,
      s3_key:      s3_key
    }
  end

  private

  def collect_page_infos(splitter, _total)
    pages = []
    splitter.each_page do |page_num, page_binary|
      pages << { number: page_num, binary: page_binary, force_opus: false, model: BatchChunkingPrompt::MODEL_TEXT }
    end
    pages
  end

  def build_filter_results(pages, filename, sha256)
    proxies = pages.map { |p| PageProxy.new(p[:number], p[:binary]) }
    PageRelevanceFilter.filter_pages(
      pages:          proxies,
      filename:       filename,
      correlation_id: "ingest:#{sha256.to_s[0, 12]}"
    )
  end

  def apply_filters(pages, filter_results)
    pages.select do |page|
      result = filter_results[page[:number]] || { keep: true, reason: :missing, source: :fallback }

      if result[:force_opus] && result[:keep]
        page[:model]      = BatchChunkingPrompt::MODEL_MULTIMODAL
        page[:force_opus] = true
      end

      Rails.logger.info(
        "ManualBatchIngestionService filter: p#{page[:number]} " \
        "#{result[:keep] ? 'keep' : 'drop'} (#{result[:reason]}, #{result[:source]})"
      )

      result[:keep]
    end
  end

  def build_batch_requests(kept_pages, filename, sha256, locale, _hint_slot)
    total = kept_pages.size

    kept_pages.each_with_index.map do |page, idx|
      # Anchor page (first kept) gets locale; others omit it.
      page_locale = idx.zero? ? locale : nil

      {
        custom_id: custom_id_for(sha256, page[:number]),
        params: {
          model:      page[:model],
          max_tokens: BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
          system:     BatchChunkingPrompt::SYSTEM_BLOCKS,
          messages: [
            {
              role:    "user",
              content: BatchChunkingPrompt.page_user_content(
                binary:      page[:binary],
                page_number: page[:number],
                total_pages: total,
                filename:    filename,
                locale:      page_locale
              )
            }
          ]
        }
      }
    end
  end

  def custom_id_for(sha256, page_number)
    format(CUSTOM_ID_PAGE_PATTERN, sha256[0..15], page_number)
  end

  def empty_result
    { batch_id: nil, page_customs: {}, kept_pages: [], total_pages: 0, filename: nil, sha256: nil, s3_key: nil }
  end
end
