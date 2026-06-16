# frozen_string_literal: true

# Phase 2 of web manual batch ingestion:
#   Polls Anthropic Batch status, and when complete:
#     streams results → ChunkMergerService → BatchResultsParserService (manual_batch_v1) →
#     BulkKbSyncService → BedrockIngestionJob.
#
# Polling: retries up to MAX_ATTEMPTS with exponential backoff via Solid Queue.
class IngestManualBatchResultsJob < ApplicationJob
  queue_as :bulk_ingestion

  MAX_ATTEMPTS  = 24   # ~24h with 1h steps
  POLL_INTERVAL = 1.hour

  discard_on ActiveJob::DeserializationError
  discard_on ActiveRecord::RecordNotFound

  # @param web_manual_batch_id [Integer, nil] durable context row for new jobs
  # @param batch_id            [String, nil] legacy Anthropic batch id
  # @param cache_key           [String, nil] legacy Solid Cache key
  # @param attempt             [Integer] current polling attempt (1-based)
  def perform(web_manual_batch_id: nil, batch_id: nil, cache_key: nil, attempt: 1)
    web_manual_batch = load_web_manual_batch(web_manual_batch_id)
    batch_context    = web_manual_batch ? context_from_record(web_manual_batch) : Rails.cache.read(cache_key)

    unless batch_context
      Rails.logger.warn("IngestManualBatchResultsJob: cache miss for #{cache_key} — batch_id=#{batch_id}")
      return
    end

    batch_context = batch_context.with_indifferent_access
    batch_id ||= batch_context[:batch_id]
    return if web_manual_batch&.status.in?(%w[parsed syncing complete])

    batch_client = ClaudeBatchClient.new
    status       = batch_client.retrieve(batch_id: batch_id)

    case status.processing_status.to_s
    when "in_progress"
      web_manual_batch&.update!(status: "in_progress")
      if attempt >= MAX_ATTEMPTS
        web_manual_batch&.update!(
          status:        "failed",
          error_message: "Batch still in_progress after #{attempt} attempts"
        )
        broadcast_failed(web_manual_batch, batch_context)
        Rails.logger.error("IngestManualBatchResultsJob: batch #{batch_id} still in_progress after #{attempt} attempts — giving up")
        return
      end
      poll_args = web_manual_batch ? { web_manual_batch_id: web_manual_batch.id } : { batch_id: batch_id, cache_key: cache_key }
      self.class.set(wait: POLL_INTERVAL).perform_later(**poll_args, attempt: attempt + 1)
      nil
    when "ended"
      web_manual_batch&.update!(status: "parsing")
      ingest_results(batch_context, batch_client, web_manual_batch: web_manual_batch)
    else
      web_manual_batch&.update!(
        status:        "failed",
        error_message: "Unexpected batch status #{status.processing_status}"
      )
      broadcast_failed(web_manual_batch, batch_context)
      Rails.logger.warn("IngestManualBatchResultsJob: unexpected batch status '#{status.processing_status}' for #{batch_id}")
    end
  rescue StandardError => e
    web_manual_batch&.update_columns(status: "failed", error_message: e.message)
    Rails.logger.error("IngestManualBatchResultsJob[#{batch_id}]: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    raise
  end

  private

  def ingest_results(ctx, batch_client, web_manual_batch: nil)
    ctx = ctx.with_indifferent_access
    batch_id     = ctx[:batch_id]
    filename     = ctx[:filename]
    sha256       = ctx[:sha256]
    s3_key       = ctx[:s3_key]
    page_customs = ctx[:page_customs] || {}  # { page_num => custom_id }
    conv_session_id = ctx[:conv_session_id]
    kb_doc_id       = ctx[:kb_doc_id]

    # Invert: custom_id → page_num for result lookup
    customs_to_page = page_customs.invert

    page_results = []

    batch_client.results_each(batch_id: batch_id) do |result|
      page_num = customs_to_page[result.custom_id]
      unless page_num
        Rails.logger.warn("IngestManualBatchResultsJob: unknown custom_id=#{result.custom_id} in batch #{batch_id}")
        next
      end

      if result.result.type.to_s == "succeeded"
        message     = result.result.message
        text        = extract_text(message)
        model       = message.model.to_s
        # O3′: capture stop_reason so truncated pages are visible in telemetry and
        # ready for the shared bounded retry that E3a will port to this chain.
        stop_reason = message.respond_to?(:stop_reason) ? message.stop_reason.to_s.presence : nil
        track_page_usage(message, filename, page_num, ctx[:kept_pages]&.size || page_customs.size,
                         sha256: sha256, stop_reason: stop_reason)
        page_results << { page_number: page_num, text: text, model: model, stop_reason: stop_reason }
      else
        Rails.logger.warn("IngestManualBatchResultsJob: #{filename} p#{page_num} #{result.result.type} — skipping")
      end
    end

    if page_results.empty?
      web_manual_batch&.update!(status: "failed", error_message: "No succeeded batch results")
      broadcast_failed(web_manual_batch, ctx)
      Rails.logger.warn("IngestManualBatchResultsJob: no succeeded results for #{filename} batch #{batch_id}")
      return
    end

    page_results.sort_by! { |r| r[:page_number] }

    # B.1 paso 12: shared bounded retry for truncated OR invalid-JSON pages
    # (V1 page-6 failure mode). Retry only — automatic long-manual routing
    # stays untouched until E3a. No asset ledger row exists on this chain;
    # each retry is still tracked once by ClaudeChunkingClient.
    page_results = BatchPageRetryService.new.retry_failed_pages!(
      page_results:    page_results,
      s3_key:          s3_key,
      filename:        filename,
      sha256:          sha256,
      tracking_prefix: "web_batch_retry"
    )

    merged_json = ChunkMergerService.merge(page_results)

    s3 = S3DocumentsService.new
    asset = ChunkAsset.new(filename: filename, sha256: sha256, s3_key: s3_key, content_type: "application/pdf")
    chunk_asset = BatchResultsParserService.new(s3_service: s3).call(
      asset:          asset,
      raw_json:       merged_json,
      ingestion_path: "manual_batch_v1"
    )

    web_manual_batch&.update!(
      status:           "parsed",
      canonical_name:   chunk_asset.canonical_name.to_s,
      aliases:          Array(chunk_asset.aliases),
      chunks_count:     chunk_asset.chunks_count,
      chunks_s3_prefix: chunk_asset.chunks_s3_prefix,
      error_message:    nil
    )

    uploaded_filenames = [ filename ]
    web_v1_metadata    = [ {
      "filename"         => filename,
      "canonical_name"   => chunk_asset.canonical_name.to_s,
      "aliases"          => Array(chunk_asset.aliases),
      "summary"          => chunk_asset.summary.to_s.presence,
      "companion_offer"  => chunk_asset.companion_offer.to_s.presence,
      "chunks_s3_prefix" => chunk_asset.chunks_s3_prefix.to_s.presence,
      "partial_pages"    => Array(chunk_asset.degraded_pages),
      "processing_scope" => "full_manual",
      "web_manual_batch_id" => web_manual_batch&.id
    } ]

    sync_result = BulkKbSyncService.new.sync!(uploaded_filenames: uploaded_filenames, locale: ctx[:locale])
    if sync_result.blank?
      web_manual_batch&.update!(
        status:        "failed",
        error_message: "Bedrock sync did not start"
      )
      broadcast_failed(web_manual_batch, ctx)
      return
    end

    web_manual_batch&.update!(status: "syncing")

    BedrockIngestionJob.perform_later(
      sync_result[:job_id],
      uploaded_filenames,
      kb_id:           sync_result[:kb_id],
      data_source_id:  sync_result[:data_source_id],
      conv_session_id: conv_session_id,
      kb_document_ids: [ kb_doc_id ].compact,
      web_v1_metadata: web_v1_metadata,
      locale:          ctx[:locale]
    )

    Rails.logger.info("IngestManualBatchResultsJob: #{filename} batch #{batch_id} → Bedrock sync started")
  end

  def load_web_manual_batch(id)
    return if id.blank?

    WebManualBatch.find(id)
  end

  def context_from_record(batch)
    {
      batch_id:        batch.claude_batch_id,
      filename:        batch.filename,
      sha256:          batch.sha256,
      s3_key:          batch.s3_key,
      page_customs:    batch.page_customs.to_h.transform_keys(&:to_i),
      kept_pages:      Array(batch.kept_pages),
      conv_session_id: batch.conv_session_id,
      kb_doc_id:       batch.kb_document_id,
      locale:          batch.locale
    }
  end

  def broadcast_failed(web_manual_batch, ctx)
    KbSyncBroadcaster.failed(
      filenames: [ ctx[:filename] ],
      reason:    "manual_batch_failed",
      locale:    web_manual_batch&.locale || ctx[:locale]
    )
  rescue StandardError => e
    Rails.logger.warn("IngestManualBatchResultsJob: failed to broadcast manual batch failure — #{e.message}")
  end

  def extract_text(message)
    content = message.respond_to?(:content) ? message.content : Array(message["content"])
    content.each do |block|
      type = block.respond_to?(:type) ? block.type : block["type"]
      return (block.respond_to?(:text) ? block.text : block["text"]) if type.to_s == "text"
    end
    raise "No text block in batch result message"
  end

  def track_page_usage(message, filename, page_num, total_kept, sha256: nil, stop_reason: nil)
    usage = message.respond_to?(:usage) ? message.usage : nil
    return if usage.nil?

    model_id = message.model.to_s
    model_id = "#{model_id}-batch" unless model_id.end_with?("-batch")

    TrackBedrockQueryJob.perform_later(
      model_id:              model_id,
      user_query:            "web_batch: #{filename} p#{page_num}/#{total_kept}",
      latency_ms:            0,
      input_tokens:          usage.input_tokens.to_i,
      output_tokens:         usage.output_tokens.to_i,
      cache_read_tokens:     safe_token(usage, :cache_read_input_tokens),
      cache_creation_tokens: safe_token(usage, :cache_creation_input_tokens),
      route:                 "batch",
      attempt:               1,
      max_tokens:            BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
      stop_reason:           stop_reason,
      correlation_id:        sha256.present? ? "ingest:#{sha256.to_s[0, 12]}:p#{page_num}" : nil,
      source:                "ingestion_parse"
    )
  rescue StandardError => e
    Rails.logger.warn("IngestManualBatchResultsJob: failed to enqueue TrackBedrockQueryJob — #{e.message}")
  end

  def safe_token(usage, method_name)
    val = usage.respond_to?(method_name) ? usage.public_send(method_name).to_i : 0
    val.positive? ? val : nil
  end
end
