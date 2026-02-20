# frozen_string_literal: true

# app/services/kb_sync_service.rb
#
# Triggers a Knowledge Base re-ingestion job so that newly uploaded
# documents/images in S3 get indexed. Designed to be called async
# (in a thread) so it doesn't block the user's response.

require 'aws-sdk-bedrockagent'

class KbSyncService
  include AwsClientInitializer

  def initialize(kb_id: nil)
    client_options = build_aws_client_options
    @client = Aws::BedrockAgent::Client.new(client_options)
    @kb_id = kb_id.presence ||
             ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
             Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
  end

  # Starts an ingestion job. Safe to call frequently — Bedrock will queue
  # if another job is already running.
  def sync!
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

    Rails.logger.info("KbSyncService: Ingestion job started — #{job.ingestion_job.ingestion_job_id} (#{job.ingestion_job.status})")
    job.ingestion_job.ingestion_job_id
  rescue StandardError => e
    Rails.logger.error("KbSyncService: Failed to start ingestion — #{e.message}")
    nil
  end

  private

  def find_data_source_id
    ds_list = @client.list_data_sources(knowledge_base_id: @kb_id)
    ds_list.data_source_summaries.first&.data_source_id
  rescue StandardError => e
    Rails.logger.error("KbSyncService: Failed to list data sources — #{e.message}")
    nil
  end
end
