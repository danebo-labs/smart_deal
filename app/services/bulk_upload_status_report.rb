# frozen_string_literal: true

# Read-only snapshot of a bulk ingestion run: asset states, the error behind each
# failure, and the field_records the parser discarded.
#
# All three durable copies live in the table on purpose. The pipeline advances
# state with `update_columns`/`update_all` and logs discards to `Rails.logger`,
# which rotates out of a 10m json-file with no `max-file`, so the log is not a
# record — `status`, `error_message` and `dropped_field_records` are.
class BulkUploadStatusReport
  TERMINAL_STATUSES = %w[complete failed].freeze

  Failure = Struct.new(:filename, :error_message, keyword_init: true)
  Discard = Struct.new(:filename, :count, :reasons, keyword_init: true)

  Snapshot = Struct.new(
    :upload_id, :original_filename, :status, :error_message,
    :batches, :asset_counts, :failures, :discards,
    keyword_init: true
  ) do
    def terminal? = TERMINAL_STATUSES.include?(status)

    def to_s
      line = "BU#{upload_id} #{original_filename} status=#{status} batches=#{batches} " \
             "assets=[#{asset_counts.sort.map { |status, count| "#{status}:#{count}" }.join(' ')}]"
      line += " error=#{error_message}" if error_message.present?
      line
    end
  end

  def initialize(bulk_upload)
    @bulk_upload = bulk_upload
  end

  # Reads bypass the query cache: `bin/rails runner` leaves it on for the whole
  # process, so a polling loop would otherwise repeat its first answer forever.
  def call
    ActiveRecord::Base.uncached do
      upload = @bulk_upload.reload
      assets = upload.bulk_upload_assets

      Snapshot.new(
        upload_id:         upload.id,
        original_filename: upload.original_filename,
        status:            upload.status,
        error_message:     upload.error_message,
        batches:           upload.processing_batch_ids.size,
        asset_counts:      assets.group(:status).count,
        failures:          failures_for(assets),
        discards:          discards_for(assets)
      )
    end
  end

  private

  def failures_for(assets)
    assets.where(status: "failed").pluck(:filename, :error_message).map do |filename, error_message|
      Failure.new(filename: filename, error_message: error_message)
    end
  end

  def discards_for(assets)
    assets.where("jsonb_array_length(dropped_field_records) > 0")
          .pluck(:filename, :dropped_field_records)
          .map do |filename, records|
            Discard.new(
              filename: filename,
              count:    records.size,
              reasons:  records.map { |record| record["reason"] }.tally
            )
          end
  end
end
