# frozen_string_literal: true

# Streams JSONL results from Anthropic for a completed bulk batch, then:
#
#   - Images  (field_photo_v1): FieldPhotoResultsParser → BatchResultsParserService.
#   - PDFs    (manual_batch_v1): accumulate page results → ChunkMergerService → parser.
#   - Tokens  accumulated (+=) across all pages per asset; model_id gets "-batch" suffix.
#   - user_query: "bulk_parse: <filename>" (images) | "bulk_batch: <filename> pN/M" (pages).
#
# After all results → BulkKbSyncService#sync!, bedrock_ingestion_job_id, → PollBulkBedrock.
class IngestBatchResultsJob < ApplicationJob
  queue_as :bulk_ingestion
  discard_on ActiveRecord::RecordNotFound

  self.log_arguments = false

  PAGE_ID_REGEX = /_p(\d+)\z/

  def perform(bulk_upload_id)
    bulk_upload  = BulkUpload.find(bulk_upload_id)
    return if bulk_upload.status == "failed"

    parser       = BatchResultsParserService.new
    batch_client = ClaudeBatchClient.new

    # Build a map: any custom_id (primary or per-page) → asset
    asset_map = {}
    bulk_upload.bulk_upload_assets.where(status: "in_batch").find_each do |asset|
      asset.all_custom_ids.each { |cid| asset_map[cid] = asset }
    end

    # page_buffers: asset_id → [{ page_number:, text:, model:, usage: }]
    page_buffers = Hash.new { |h, k| h[k] = [] }

    batch_client.results_each(batch_id: bulk_upload.claude_batch_id) do |result|
      asset = asset_map[result.custom_id]
      unless asset
        Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: unknown custom_id=#{result.custom_id}")
        next
      end

      if result.result.type.to_s == "succeeded"
        message = result.result.message

        if page_id?(result.custom_id)
          # PDF page — buffer for ChunkMerger
          page_num    = PAGE_ID_REGEX.match(result.custom_id)[1].to_i
          text        = extract_text(message)
          stop_reason = message.respond_to?(:stop_reason) ? message.stop_reason.to_s : nil
          # batch_stop_reason is immutable (telemetry for the Batch attempt);
          # stop_reason is overwritten by retry_truncated_pages! with the latest attempt.
          page_buffers[asset.id] << { page_number: page_num, text: text, model: message.model.to_s,
                                      usage: message.usage, stop_reason: stop_reason, batch_stop_reason: stop_reason }

        elsif asset.ingestion_path == "field_photo_v1"
          # Photo — parse with FieldPhotoResultsParser
          text        = extract_text(message)
          raw_json    = FieldPhotoResultsParser.to_envelope(text)
          ingestion_p = "field_photo_v1"
          begin
            parser.call(asset: asset, raw_json: JSON.generate(raw_json), ingestion_path: ingestion_p)
          rescue BatchResultsParserService::ParseError => e
            Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: FieldPhotoResultsParser failed #{asset.filename} — #{e.message}")
          end
          track_asset_usage(asset, message,
            user_query:     "bulk_parse: #{asset.filename}",
            ingestion_path: ingestion_p,
            correlation_id: correlation_id_for(asset))

        else
          # Defensive: unknown custom_id type — log and skip rather than silently swallow
          Rails.logger.warn(
            "IngestBatchResultsJob[#{bulk_upload_id}]: unexpected result type for #{asset.filename} " \
            "(custom_id=#{result.custom_id}, ingestion_path=#{asset.ingestion_path.inspect}) — skipping"
          )
        end

      else
        msg = "Batch result type '#{result.result.type}' for #{asset.filename}"
        asset.update_columns(status: "failed", error_message: msg)
        asset.broadcast_replace!
        Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: #{msg}")
      end
    end

    # Flush PDF page buffers → ChunkMerger → parser
    page_buffers.each do |asset_id, page_results|
      asset = bulk_upload.bulk_upload_assets.find_by(id: asset_id)
      next unless asset

      page_results.sort_by! { |r| r[:page_number] }
      page_results = retry_truncated_pages!(asset, page_results)
      total_kept = page_results.size

      begin
        merged_json = ChunkMergerService.merge(page_results)
        parser.call(asset: asset, raw_json: merged_json, ingestion_path: "manual_batch_v1")
      rescue ArgumentError, BatchResultsParserService::ParseError => e
        asset.update_columns(status: "failed", error_message: e.message)
        asset.broadcast_replace!
        Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: merge/parse failed #{asset.filename} — #{e.message}")
        next
      end

      # Accumulate tokens across all pages.
      # pr[:usage] / pr[:batch_stop_reason] are always the ORIGINAL Batch attempt:
      # retry_truncated_pages! mutates text/stop_reason but tracks its own direct
      # usage separately (one row per retry call) — no double counting.
      page_results.each do |pr|
        next unless pr[:usage]
        track_asset_usage_accumulate(asset, pr[:usage], pr[:model],
          page_num:    pr[:page_number],
          total_kept:  total_kept,
          stop_reason: pr[:batch_stop_reason])
      end
    end

    # Assets still in_batch after streaming → no result returned
    bulk_upload.bulk_upload_assets.where(status: "in_batch").find_each do |asset|
      msg = "No batch result returned for this asset (custom_id=#{asset.custom_id})"
      asset.update_columns(status: "failed", error_message: msg)
      asset.broadcast_replace!
      Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: #{msg}")
    end

    parsed_assets = bulk_upload.bulk_upload_assets.where(status: "parsed")
    unless parsed_assets.exists?
      Rails.logger.warn("IngestBatchResultsJob[#{bulk_upload_id}]: no parsed assets, skipping Bedrock sync")
      bulk_upload.derive_status!
      return
    end

    sync_result = BulkKbSyncService.new.sync!(uploaded_filenames: parsed_assets.pluck(:canonical_name))
    unless sync_result
      msg = "Bedrock sync did not start — check BEDROCK_KNOWLEDGE_BASE_ID, BEDROCK_BULK_DATA_SOURCE_ID / BEDROCK_DATA_SOURCE_ID, and AWS credentials."
      Rails.logger.error("IngestBatchResultsJob[#{bulk_upload_id}]: BulkKbSyncService returned nil — #{msg}")
      parsed_assets.find_each do |asset|
        asset.update_columns(status: "failed", error_message: msg)
        asset.broadcast_replace!
      end
      bulk_upload.update_columns(error_message: msg) if bulk_upload.error_message.blank?
      bulk_upload.derive_status!
      return
    end

    bulk_upload.update_columns(bedrock_ingestion_job_id: sync_result[:job_id])
    parsed_assets.update_all(status: "syncing")
    parsed_assets.reload.each(&:broadcast_replace!)

    PollBulkBedrockIngestionJob.set(wait: 5.seconds).perform_later(bulk_upload_id)
    Rails.logger.info("IngestBatchResultsJob[#{bulk_upload_id}]: sync started job=#{sync_result[:job_id]}")
  rescue StandardError => e
    Rails.logger.error("IngestBatchResultsJob[#{bulk_upload_id}]: #{e.message}")
    raise
  end

  private

  def page_id?(custom_id)
    PAGE_ID_REGEX.match?(custom_id)
  end

  def extract_text(message)
    content = message.respond_to?(:content) ? message.content : Array(message["content"])
    content.each do |block|
      type = block.respond_to?(:type) ? block.type : block["type"]
      return (block.respond_to?(:text) ? block.text : block["text"]) if type.to_s == "text"
    end
    raise BatchResultsParserService::ParseError, "No text block in Claude response"
  end

  # Gate 9R I0: same scheme as SingleFileChunkingService#correlation_id so the
  # cost matrix groups attempts identically across sync and batch routes.
  def correlation_id_for(asset, page_num = nil)
    base = "ingest:#{asset.sha256.to_s[0, 12]}"
    page_num ? "#{base}:p#{page_num}" : base
  end

  # Single-call tracking: token update + TrackBedrockQueryJob (non-accumulating — for images/legacy).
  def track_asset_usage(asset, message, user_query:, ingestion_path:, correlation_id: nil)
    usage = message.respond_to?(:usage) ? message.usage : nil
    return if usage.nil?

    input_tokens   = usage.input_tokens.to_i
    output_tokens  = usage.output_tokens.to_i
    cache_read     = safe_token(usage, :cache_read_input_tokens)
    cache_creation = safe_token(usage, :cache_creation_input_tokens)

    asset.update_columns(
      claude_input_tokens:  asset.claude_input_tokens.to_i + input_tokens + cache_read + cache_creation,
      claude_output_tokens: asset.claude_output_tokens.to_i + output_tokens
    )

    # Always -batch: results come from Anthropic Batch API (batch pricing), regardless of cost_v2 routing.
    model_id = "#{message.model}-batch"

    TrackBedrockQueryJob.perform_later(
      model_id:              model_id,
      user_query:            user_query,
      latency_ms:            0,
      input_tokens:          input_tokens,
      output_tokens:         output_tokens,
      cache_read_tokens:     cache_read.positive?     ? cache_read     : nil,
      cache_creation_tokens: cache_creation.positive? ? cache_creation : nil,
      route:                 "batch",
      attempt:               1,
      max_tokens:            BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
      stop_reason:           (message.respond_to?(:stop_reason) ? message.stop_reason.to_s.presence : nil),
      correlation_id:        correlation_id,
      source:                "ingestion_parse"
    )
  end

  # Per-page token accumulation for PDF batches.
  def track_asset_usage_accumulate(asset, usage, model, page_num:, total_kept:, stop_reason: nil)
    input_tokens   = usage.input_tokens.to_i
    output_tokens  = usage.output_tokens.to_i
    cache_read     = safe_token(usage, :cache_read_input_tokens)
    cache_creation = safe_token(usage, :cache_creation_input_tokens)

    asset.update_columns(
      claude_input_tokens:  asset.claude_input_tokens.to_i + input_tokens + cache_read + cache_creation,
      claude_output_tokens: asset.claude_output_tokens.to_i + output_tokens
    )

    cache_hit_ratio = (cache_read + cache_creation) > 0 ? cache_read.to_f / (cache_read + input_tokens) : 0.0
    Rails.logger.info(
      "IngestBatchResultsJob: #{asset.filename} p#{page_num}/#{total_kept} " \
      "cache_read=#{cache_read} input=#{input_tokens} hit_ratio=#{cache_hit_ratio.round(3)}"
    )

    TrackBedrockQueryJob.perform_later(
      model_id:              "#{model}-batch",
      user_query:            "bulk_batch: #{asset.filename} p#{page_num}/#{total_kept}",
      latency_ms:            0,
      input_tokens:          input_tokens,
      output_tokens:         output_tokens,
      cache_read_tokens:     cache_read.positive?     ? cache_read     : nil,
      cache_creation_tokens: cache_creation.positive? ? cache_creation : nil,
      route:                 "batch",
      attempt:               1,
      max_tokens:            BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
      stop_reason:           stop_reason.presence,
      correlation_id:        correlation_id_for(asset, page_num),
      source:                "ingestion_parse"
    )
  end

  def safe_token(usage, method_name)
    val = usage.respond_to?(method_name) ? usage.public_send(method_name).to_i : 0
    val.positive? ? val : 0
  end

  # B.1 paso 12: shared bounded retry (BatchPageRetryService) for pages that are
  # truncated OR returned invalid JSON — the V1 page-6 failure mode. The Batch
  # usage row is preserved; each direct retry is tracked once by the client and
  # accumulated on the asset via on_usage.
  def retry_truncated_pages!(asset, page_results)
    BatchPageRetryService.new.retry_failed_pages!(
      page_results: page_results,
      s3_key:       asset.s3_key,
      filename:     asset.filename,
      sha256:       asset.sha256,
      on_usage:     ->(usage) { accumulate_asset_usage(asset, usage) }
    )
  end

  def accumulate_asset_usage(asset, usage)
    cache_read     = safe_token(usage, :cache_read_input_tokens)
    cache_creation = safe_token(usage, :cache_creation_input_tokens)

    asset.update_columns(
      claude_input_tokens: asset.claude_input_tokens.to_i +
        usage.input_tokens.to_i + cache_read + cache_creation,
      claude_output_tokens: asset.claude_output_tokens.to_i + usage.output_tokens.to_i
    )
  end
end
