# frozen_string_literal: true

# Thin wrapper around KbSyncService that injects BEDROCK_BULK_DATA_SOURCE_ID
# so bulk-ingestion jobs use the separate "No chunking" Bedrock data source
# (ID: 8DUTRUCDTS) instead of the default single-file data source.
class BulkKbSyncService
  def initialize(kb_sync_service: nil)
    bulk_ds_id = ENV["BEDROCK_BULK_DATA_SOURCE_ID"].presence ||
                 Rails.application.credentials.dig(:bedrock, :bulk_data_source_id)

    @service = kb_sync_service || KbSyncService.new(data_source_id: bulk_ds_id)
  end

  # @param uploaded_filenames [Array<String>] canonical names — forwarded to IngestionStatusService for UI
  # @param locale             [String, nil]  ISO 639-1 — forwarded to KbSyncBroadcaster.retrying on Aurora retry
  # @return [Hash, nil] { job_id:, kb_id:, data_source_id: } or nil on config error
  def sync!(uploaded_filenames: [], locale: nil)
    @service.sync!(uploaded_filenames: uploaded_filenames, locale: locale)
  end
end
