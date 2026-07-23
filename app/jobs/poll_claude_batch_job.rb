# frozen_string_literal: true

# Polls the Anthropic Batch API for a BulkUpload until the batch reaches
# "ended" status, then enqueues IngestBatchResultsJob.
#
# Uses a re-enqueue pattern (single status check per perform) to free the
# worker thread between polls — mirrors BedrockIngestionJob#perform_reenqueue.
#
# Backoff: 30s → 60s → 120s → 240s → cap 300s. Hard timeout 24h.
class PollClaudeBatchJob < ApplicationJob
  queue_as :bulk_ingestion
  discard_on ActiveRecord::RecordNotFound

  self.log_arguments = false

  INITIAL_WAIT = 30
  MAX_WAIT     = 300
  HARD_TIMEOUT = 24.hours

  # @param bulk_upload_id [Integer]
  # @param started_at_iso [String, nil]  ISO8601 of first perform (for hard timeout)
  # @param wait_seconds   [Integer]      Interval used to reach THIS call; next will double it (capped)
  def perform(bulk_upload_id, started_at_iso: nil, wait_seconds: INITIAL_WAIT)
    bulk_upload = BulkUpload.find(bulk_upload_id)
    return if bulk_upload.status == "failed"

    started_at = started_at_iso.present? ? Time.zone.parse(started_at_iso) : Time.current

    if Time.current - started_at > HARD_TIMEOUT
      mark_timed_out(bulk_upload)
      return
    end

    batch_ids = bulk_upload.processing_batch_ids
    if batch_ids.empty?
      Rails.logger.warn("PollClaudeBatchJob[#{bulk_upload_id}]: missing claude_batch_id, skipping")
      return
    end

    client = ClaudeBatchClient.new
    statuses = batch_ids.to_h do |batch_id|
      batch = client.retrieve(batch_id: batch_id)
      [ batch_id, batch.processing_status.to_s ]
    end

    if statuses.values.all?("ended")
      IngestBatchResultsJob.perform_later(bulk_upload_id)
    else
      next_wait = [ wait_seconds * 2, MAX_WAIT ].min
      self.class.set(wait: wait_seconds.seconds).perform_later(
        bulk_upload_id,
        started_at_iso: started_at.iso8601,
        wait_seconds:   next_wait
      )
      Rails.logger.info(
        "PollClaudeBatchJob[#{bulk_upload_id}]: statuses=#{statuses.values.join(',')}, " \
        "re-enqueue in #{wait_seconds}s"
      )
    end
  rescue StandardError => e
    Rails.logger.error("PollClaudeBatchJob[#{bulk_upload_id}]: #{e.message}")
    raise
  end

  private

  def mark_timed_out(bulk_upload)
    msg = "Claude batch timed out after 24h"
    bulk_upload.update_columns(status: "failed", error_message: msg)
    bulk_upload.bulk_upload_assets.where(status: "in_batch").update_all(status: "failed", error_message: msg)
    Rails.logger.warn("PollClaudeBatchJob: #{msg} for BulkUpload##{bulk_upload.id}")
  end
end
