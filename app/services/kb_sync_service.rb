# frozen_string_literal: true

# app/services/kb_sync_service.rb
#
# Triggers a Knowledge Base re-ingestion job so that newly uploaded
# documents/images in S3 get indexed. Designed to be called async
# (in a thread) so it doesn't block the user's response.
#
# Multi-tenant: pass tenant: or data_source_id: to use tenant-specific config.
# When tenant is present, uses tenant.bedrock_config.data_source_id.
# Otherwise uses BEDROCK_DATA_SOURCE_ID env / credentials.

require 'aws-sdk-bedrockagent'

class KbSyncService
  include AwsClientInitializer

  def initialize(kb_id: nil, data_source_id: nil, tenant: nil)
    client_options = build_aws_client_options
    @client = Aws::BedrockAgent::Client.new(client_options)
    @tenant = tenant
    @data_source_id_override = data_source_id
    @kb_id = kb_id.presence ||
             (tenant&.bedrock_config&.knowledge_base_id if tenant&.respond_to?(:bedrock_config)) ||
             ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
             Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
  end

  # Starts an ingestion job. Safe to call frequently — Bedrock will queue
  # if another job is already running.
  # @param uploaded_filenames [Array<String>] Document names being indexed (for status UI)
  # @return [Hash, nil] { job_id:, kb_id:, data_source_id: } or nil on failure
  def sync!(uploaded_filenames: [])
    unless @kb_id
      Rails.logger.warn("KbSyncService: KB ID not configured, skipping sync")
      return nil
    end

    ds_id = find_data_source_id
    return nil unless ds_id

    job = @client.start_ingestion_job(
      knowledge_base_id: @kb_id,
      data_source_id: ds_id
    )

    job_id = job.ingestion_job.ingestion_job_id
    Rails.logger.info("KbSyncService: Ingestion job started — #{job_id} (#{job.ingestion_job.status})")

    IngestionStatusService.new(kb_id: @kb_id, data_source_id: ds_id).register_ingestion(job_id, uploaded_filenames)
    { job_id: job_id, kb_id: @kb_id, data_source_id: ds_id }
  rescue StandardError => e
    Rails.logger.error("KbSyncService: Failed to start ingestion — #{e.message}")
    nil
  end

  private

  def find_data_source_id
    ds_list = @client.list_data_sources(knowledge_base_id: @kb_id)
    summaries = ds_list.data_source_summaries

    return nil if summaries.empty?

    preferred_id = @data_source_id_override.presence
    preferred_id ||= @tenant.bedrock_config.data_source_id if @tenant&.respond_to?(:bedrock_config) && @tenant.bedrock_config&.respond_to?(:data_source_id)
    preferred_id ||= ENV['BEDROCK_DATA_SOURCE_ID'].presence
    preferred_id ||= Rails.application.credentials.dig(:bedrock, :data_source_id)

    if preferred_id
      ds = summaries.find { |s| s.data_source_id == preferred_id }
      if ds
        Rails.logger.info("KbSyncService: Using preferred data source — #{preferred_id}")
        return ds.data_source_id
      else
        Rails.logger.warn("KbSyncService: Preferred data source #{preferred_id} not found, using first available")
      end
    end

    summaries.first&.data_source_id
  rescue StandardError => e
    Rails.logger.error("KbSyncService: Failed to list data sources — #{e.message}")
    nil
  end
end
