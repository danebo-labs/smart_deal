# frozen_string_literal: true

# Gate 9R B.1 (paso 12) — shared bounded retry for per-page Batch results.
#
# V1 (docs/GATE9_V1_2026-06-12.md) failed because a Batch page ended with
# stop_reason=end_turn but unparseable JSON and the Batch route only retried
# max_tokens truncations. A page needs a retry when it is truncated OR its output
# remains unparseable after deterministic normalization — the same two-signal
# rule the sync ladder already applies (SingleFileChunkingService#call_with_page_cap_retry).
#
# One service shared by every Batch results consumer:
#   - IngestBatchResultsJob (bulk ZIP route, active)
#   - IngestManualBatchResultsJob (web long-manual Batch chain)
#
# Billing invariants (I0):
#   - The original Batch attempt row/usage is never replaced.
#   - Each direct retry is one ClaudeChunkingClient call → exactly one
#     BedrockQuery row (route "bulk_retry", attempt 2..3, page correlation_id).
#   - `on_usage` lets callers accumulate retry usage on their own ledger row
#     (BulkUploadAsset) without double counting.
#
# This service makes no calls by itself at boot/test time; Anthropic calls only
# happen when a results consumer passes it pages that actually need a retry.
class BatchPageRetryService
  include AwsClientInitializer

  # Rungs AFTER the 8k Batch attempt (O3′ ladder: 8k batch → 16k → 32k direct).
  RETRY_TOKEN_LADDER = [
    BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS,
    BatchChunkingPrompt::MAX_TOKENS
  ].freeze

  # A page result needs a paid retry when the model hit the output cap OR the
  # output cannot be parsed after deterministic normalization — both previously
  # degraded the page to a marker.
  # @param page_result [Hash] { text:, stop_reason:, ... }
  def self.needs_retry?(page_result)
    page_result[:stop_reason] == "max_tokens" || !parseable_json?(page_result[:text])
  end

  # Canonical fence-tolerant parseability check, mirroring
  # ChunkMergerService#parse_page_result and BatchResultsParserService
  # normalization so retry decisions and downstream consumers accept exactly
  # the same outputs. SingleFileChunkingService delegates here.
  def self.parseable_json?(text)
    LlmJsonParser.parseable?(text)
  end

  # Retries every failed page in page_results, mutating text/stop_reason in
  # place with the latest attempt. Walks RETRY_TOKEN_LADDER until the result
  # passes BOTH checks (not truncated AND parseable) or rungs are exhausted.
  #
  # @param page_results    [Array<Hash>] { page_number:, text:, model:, stop_reason:, ... }
  # @param s3_key          [String]      S3 key of the original PDF
  # @param filename        [String]      original filename (tracking)
  # @param sha256          [String]      document SHA-256 (correlation)
  # @param tracking_prefix [String]      user_query prefix ("bulk_retry" | "web_batch_retry")
  # @param on_usage        [Proc, nil]   called once per billed retry with the usage object
  # @return [Array<Hash>] the same page_results array
  def retry_failed_pages!(page_results:, s3_key:, filename:, sha256:,
                          tracking_prefix: "bulk_retry", on_usage: nil)
    failed = page_results.select { |pr| self.class.needs_retry?(pr) }
    return page_results if failed.empty?

    reasons = failed.map { |pr| "p#{pr[:page_number]}:#{retry_reason(pr)}" }.join(", ")
    Rails.logger.warn(
      "BatchPageRetryService: #{filename} has #{failed.size} failed page(s) [#{reasons}] — " \
      "retrying direct #{RETRY_TOKEN_LADDER.first / 1000}k"
    )

    pdf_binary = download_source_pdf(s3_key, filename)
    return page_results if pdf_binary.nil?

    # The anchor (lowest-numbered kept page) must keep its ANCHOR_PAGE role on
    # retry so it still emits S0/summary/companion_offer; all others stay CONTENT_PAGE.
    anchor_page_number = page_results.filter_map { |pr| pr[:page_number] }.min

    retry_extracted_pages!(pdf_binary, failed.index_by { |pr| pr[:page_number] },
                           total_kept: page_results.size,
                           filename: filename, sha256: sha256,
                           tracking_prefix: tracking_prefix, on_usage: on_usage,
                           anchor_page_number: anchor_page_number)

    page_results
  end

  private

  def retry_reason(page_result)
    page_result[:stop_reason] == "max_tokens" ? "max_tokens" : "invalid_json"
  end

  # Extracts and retries one page at a time, so the peak is one page rather than
  # the document. BulkUpload 8 died here on a SIGKILL: one unparseable page out of
  # 512 materialized all 515 pages of a 15 MiB KONE scan into a Hash at 12.3 MiB
  # each (~6.2 GiB) against a 2 GiB worker cgroup. Those 12.3 MiB were themselves
  # a defect, now fixed in PdfPageSplitterService::WHOLE_DOCUMENT_ONLY_KEYS, but
  # `only:` is the invariant that matters here: a caller retrying a handful of
  # pages must never pay for the whole document, whatever a page costs.
  #
  # A splitter failure degrades the affected pages instead of raising: the caller
  # holds a fully paid document, and losing it costs far more than a degraded page.
  def retry_extracted_pages!(pdf_binary, pending, total_kept:, **retry_options)
    PdfPageSplitterService.new(pdf_binary).each_page(only: pending.keys) do |page_number, page_binary|
      page_result = pending.delete(page_number)
      next if page_result.nil?

      retry_one_page!(page_result, page_binary, total_kept, **retry_options)
    end
  rescue StandardError => e
    Rails.logger.error(
      "BatchPageRetryService: page extraction failed for retry #{retry_options[:filename]} — #{e.message}"
    )
  ensure
    pending.each_key { |page_number| Rails.logger.warn("BatchPageRetryService: no binary for p#{page_number} retry") }
  end

  def retry_one_page!(page_result, page_bin, total_kept,
                      filename:, sha256:, tracking_prefix:, on_usage:, anchor_page_number: nil)
    page_num = page_result[:page_number]
    model    = page_result[:model].to_s.delete_suffix("-batch").presence || BatchChunkingPrompt::MODEL_TEXT
    client = ClaudeChunkingClient.new(model: model)
    user_content = BatchChunkingPrompt.page_user_content(
      binary:      page_bin,
      page_number: page_num,
      total_pages: total_kept,
      filename:    filename,
      anchor:      page_num == anchor_page_number
    )

    RETRY_TOKEN_LADDER.each_with_index do |cap, index|
      result = client.call(
        user_content:    user_content,
        filename:        filename,
        page_number:     page_num,
        total_pages:     total_kept,
        max_tokens:      cap,
        tracking_prefix: tracking_prefix,
        route:           "bulk_retry",
        attempt:         index + 2, # Batch attempt was 1
        correlation_id:  "ingest:#{sha256.to_s[0, 12]}:p#{page_num}"
      )

      page_result[:text]        = result[:text]
      page_result[:stop_reason] = result[:stop_reason]
      on_usage&.call(result[:usage])

      healthy = result[:stop_reason] != "max_tokens" && self.class.parseable_json?(result[:text])
      break if healthy

      Rails.logger.warn(
        "BatchPageRetryService: #{filename} p#{page_num} still #{retry_reason(page_result)} at #{cap} — " \
        "#{index < RETRY_TOKEN_LADDER.size - 1 ? "escalating to #{RETRY_TOKEN_LADDER[index + 1]}" : 'giving up (degraded page)'}"
      )
    rescue ClaudeChunkingClient::ApiError => e
      Rails.logger.error("BatchPageRetryService: retry failed #{filename} p#{page_num} — #{e.message}")
      break
    end
  end

  def download_source_pdf(s3_key, filename)
    s3 = Aws::S3::Client.new(build_aws_client_options)
    s3.get_object(bucket: bucket_name, key: s3_key).body.read
  rescue StandardError => e
    Rails.logger.error("BatchPageRetryService: S3 download failed for retry #{filename} — #{e.message}")
    nil
  end

  def bucket_name
    ENV["KNOWLEDGE_BASE_S3_BUCKET"].presence ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
      Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
      "document-chatbot-generic-tech-info"
  end
end
