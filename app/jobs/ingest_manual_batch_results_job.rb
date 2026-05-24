# frozen_string_literal: true

# Phase 2 of web manual batch ingestion:
#   Polls Anthropic Batch status, and when complete:
#     streams results → ChunkMergerService → BatchResultsParserService (web_v1) →
#     BulkKbSyncService → BedrockIngestionJob.
#
# Polling: retries up to MAX_ATTEMPTS with exponential backoff via Solid Queue.
# On terminal failure, logs and gives up (upload is already in KB via S3 original file).
class IngestManualBatchResultsJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS  = 24   # ~24h with 1h steps
  POLL_INTERVAL = 1.hour

  discard_on ActiveJob::DeserializationError

  # @param batch_id  [String]  Anthropic batch id
  # @param cache_key [String]  Solid Cache key for batch context
  # @param attempt   [Integer] current polling attempt (1-based)
  def perform(batch_id:, cache_key:, attempt: 1)
    batch_context = Rails.cache.read(cache_key)
    unless batch_context
      Rails.logger.warn("IngestManualBatchResultsJob: cache miss for #{cache_key} — batch_id=#{batch_id}")
      return
    end

    batch_client = ClaudeBatchClient.new
    status       = batch_client.retrieve(batch_id: batch_id)

    case status.processing_status.to_s
    when "in_progress"
      if attempt >= MAX_ATTEMPTS
        Rails.logger.error("IngestManualBatchResultsJob: batch #{batch_id} still in_progress after #{attempt} attempts — giving up")
        return
      end
      self.class.set(wait: POLL_INTERVAL).perform_later(batch_id: batch_id, cache_key: cache_key, attempt: attempt + 1)
      nil
    when "ended"
      ingest_results(batch_context, batch_client)
    else
      Rails.logger.warn("IngestManualBatchResultsJob: unexpected batch status '#{status.processing_status}' for #{batch_id}")
    end
  rescue StandardError => e
    Rails.logger.error("IngestManualBatchResultsJob[#{batch_id}]: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    raise
  end

  private

  def ingest_results(ctx, batch_client)
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
        text  = extract_text(result.result.message)
        model = result.result.message.model.to_s
        track_page_usage(result.result.message, filename, page_num, ctx[:kept_pages]&.size || page_customs.size)
        page_results << { page_number: page_num, text: text, model: model }
      else
        Rails.logger.warn("IngestManualBatchResultsJob: #{filename} p#{page_num} #{result.result.type} — skipping")
      end
    end

    if page_results.empty?
      Rails.logger.warn("IngestManualBatchResultsJob: no succeeded results for #{filename} batch #{batch_id}")
      return
    end

    page_results.sort_by! { |r| r[:page_number] }
    merged_json = ChunkMergerService.merge(page_results)

    s3 = S3DocumentsService.new
    asset = ChunkAsset.new(filename: filename, sha256: sha256, s3_key: s3_key, content_type: "application/pdf")
    chunk_asset = BatchResultsParserService.new(s3_service: s3).call(
      asset:          asset,
      raw_json:       merged_json,
      ingestion_path: "manual_batch_v1"
    )

    uploaded_filenames = [ filename ]
    web_v1_metadata    = [ {
      "filename"        => filename,
      "canonical_name"  => chunk_asset.canonical_name.to_s,
      "aliases"         => Array(chunk_asset.aliases),
      "summary"         => chunk_asset.summary.to_s.presence,
      "companion_offer" => chunk_asset.companion_offer.to_s.presence
    } ]

    sync_result = BulkKbSyncService.new.sync!(uploaded_filenames: uploaded_filenames)
    return if sync_result.blank?

    BedrockIngestionJob.perform_later(
      sync_result[:job_id],
      uploaded_filenames,
      kb_id:           sync_result[:kb_id],
      data_source_id:  sync_result[:data_source_id],
      conv_session_id: conv_session_id,
      kb_document_ids: [ kb_doc_id ].compact,
      web_v1_metadata: web_v1_metadata
    )

    Rails.logger.info("IngestManualBatchResultsJob: #{filename} batch #{batch_id} → Bedrock sync started")
  end

  def extract_text(message)
    content = message.respond_to?(:content) ? message.content : Array(message["content"])
    content.each do |block|
      type = block.respond_to?(:type) ? block.type : block["type"]
      return (block.respond_to?(:text) ? block.text : block["text"]) if type.to_s == "text"
    end
    raise "No text block in batch result message"
  end

  def track_page_usage(message, filename, page_num, total_kept)
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
