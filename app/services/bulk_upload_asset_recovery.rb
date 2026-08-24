# frozen_string_literal: true

# Returns failed assets to `in_batch` and re-runs IngestBatchResultsJob, so a
# document lost to a parse defect is re-parsed from batch results that are
# already paid for. Anthropic keeps results ~29 days and re-reading them is not
# billed: this recovers billed pages instead of buying them again.
#
# What makes it safe is that IngestBatchResultsJob builds its custom_id map only
# from assets in `in_batch`, so every asset that already succeeded is skipped —
# its results stream past as unknown custom_ids.
#
# Recovered this way: `manual placa LCB II (parte 1).pdf` (49 pages) and
# `CMC3 SCM Synergy.pdf` (59 pages), both after a single hallucinated field
# killed the whole document.
class BulkUploadAssetRecovery
  class Error < StandardError; end

  TERMINAL_ASSET_STATUSES = %w[complete failed].freeze

  Result = Struct.new(:recovered, :enqueued, keyword_init: true) do
    def to_s
      return "nothing to recover" if recovered.empty?

      "returned #{recovered.size} asset(s) to in_batch and enqueued IngestBatchResultsJob: #{recovered.join(', ')}"
    end
  end

  # @param filenames [Array<String>, nil] recover only these; nil means every failure
  def initialize(bulk_upload, filenames: nil)
    @bulk_upload = bulk_upload
    @filenames   = Array(filenames).presence
  end

  def call!
    guard_batches_exist!
    guard_nothing_in_flight!
    guard_filenames_exist! if @filenames

    scope     = failed_scope
    recovered = scope.pluck(:filename)
    return Result.new(recovered: [], enqueued: false) if recovered.empty?

    # update_all rather than update!: these columns belong to the pipeline, and a
    # broadcast here would announce a state the job is about to change again.
    scope.update_all(status: "in_batch", error_message: nil)
    IngestBatchResultsJob.perform_later(@bulk_upload.id)

    Result.new(recovered: recovered, enqueued: true)
  end

  private

  def failed_scope
    scope = @bulk_upload.bulk_upload_assets.where(status: "failed")
    scope = scope.where(filename: @filenames) if @filenames
    scope
  end

  def guard_batches_exist!
    return if @bulk_upload.processing_batch_ids.any?

    raise Error, "BulkUpload##{@bulk_upload.id} has no batch ids — there are no results to re-read"
  end

  # Re-running the job while assets are still in flight would race the run that
  # already owns them.
  def guard_nothing_in_flight!
    in_flight = @bulk_upload.bulk_upload_assets
                            .where.not(status: TERMINAL_ASSET_STATUSES)
                            .pluck(:filename)
    return if in_flight.empty?

    raise Error, "BulkUpload##{@bulk_upload.id} still has assets in flight: #{in_flight.join(', ')}"
  end

  # A typo in a filename would otherwise look like "nothing to recover".
  def guard_filenames_exist!
    known   = @bulk_upload.bulk_upload_assets.where(filename: @filenames).pluck(:filename)
    missing = @filenames - known
    return if missing.empty?

    raise Error, "BulkUpload##{@bulk_upload.id} has no asset named: #{missing.join(', ')}"
  end
end
