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

  def initialize(kb_id: nil, data_source_id: nil, tenant: nil, client_options: nil)
    client_options ||= build_aws_client_options
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
  # @param locale             [String, nil]  ISO 639-1 — forwarded to KbSyncBroadcaster.retrying
  # @return [Hash, nil] { job_id:, kb_id:, data_source_id: } or nil on config error
  # @raise [StandardError] re-raises transient AWS/Aurora errors so callers can retry
  def sync!(uploaded_filenames: [], locale: nil)
    unless @kb_id
      Rails.logger.warn("KbSyncService: KB ID not configured, skipping sync")
      return nil
    end

    ds_id = resolved_data_source_id
    return nil unless ds_id

    job = Bedrock::AuroraColdStartRetry.with_retry(
      error_classes: [ Aws::BedrockAgent::Errors::ServiceError ],
      on_retry: ->(attempt, delay) {
        KbSyncBroadcaster.retrying(filenames: uploaded_filenames, attempt: attempt, delay: delay, locale: locale)
      }
    ) do
      @client.start_ingestion_job(
        knowledge_base_id: @kb_id,
        data_source_id: ds_id
      )
    end

    job_id = job.ingestion_job.ingestion_job_id
    Rails.logger.info("KbSyncService: Ingestion job started — #{job_id} (#{job.ingestion_job.status})")

    IngestionStatusService.new(kb_id: @kb_id, data_source_id: ds_id).register_ingestion(job_id, uploaded_filenames)
    { job_id: job_id, kb_id: @kb_id, data_source_id: ds_id }
  rescue StandardError => e
    Rails.logger.error("KbSyncService: Failed to start ingestion — #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    raise
  end

  # The configured data source, after it has been seen in this knowledge base.
  # Returns nil when that id is absent. Does not start an ingestion job and
  # does not substitute another data source.
  def resolved_data_source_id
    find_data_source_id
  end

  private

  DATA_SOURCE_LIST_LIMIT = 10

  def find_data_source_id
    preferred_id = configured_data_source_id
    summaries = data_source_summaries

    if summaries.empty?
      if preferred_id
        Rails.logger.error("KbSyncService: knowledge base #{@kb_id} has no data sources; configured data source #{preferred_id} was not selected")
      end
      return nil
    end

    if preferred_id
      ds = summaries.find { |summary| summary.data_source_id == preferred_id }
      if ds
        Rails.logger.info("KbSyncService: Using configured data source — #{preferred_id}")
        return ds.data_source_id
      end

      Rails.logger.error("KbSyncService: configured data source #{preferred_id} is not listed in knowledge base #{@kb_id}; ingestion was not started")
      return nil
    end

    summaries.first&.data_source_id
  rescue StandardError => e
    Rails.logger.error("KbSyncService: Failed to list data sources — #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    raise
  end

  def configured_data_source_id
    preferred_id = @data_source_id_override.presence
    preferred_id ||= @tenant.bedrock_config.data_source_id if @tenant&.respond_to?(:bedrock_config) && @tenant.bedrock_config&.respond_to?(:data_source_id)
    preferred_id ||= ENV['BEDROCK_DATA_SOURCE_ID'].presence
    preferred_id ||= Rails.application.credentials.dig(:bedrock, :data_source_id)
    preferred_id.presence
  end

  def data_source_summaries
    summaries = []
    token = nil
    DATA_SOURCE_LIST_LIMIT.times do
      params = { knowledge_base_id: @kb_id }
      params[:next_token] = token if token.present?
      response = @client.list_data_sources(**params)
      summaries.concat(Array(response.data_source_summaries))
      token = response.respond_to?(:next_token) ? response.next_token : nil
      return summaries if token.blank?
    end

    raise "KbSyncService: data source list for #{@kb_id} did not finish; ingestion was not started"
  end
end
