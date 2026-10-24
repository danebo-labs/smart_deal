# frozen_string_literal: true

# app/services/ingestion_status_service.rb
#
# Tracks Knowledge Base ingestion job status to show which documents are
# currently being indexed vs already indexed.
#
# Multi-tenant: pass data_source_id: when polling from a job (worker has no tenant context).

require 'aws-sdk-bedrockagent'

class IngestionStatusService
  include AwsClientInitializer

  CACHE_KEY = 'kb_ingestion_info'
  CACHE_TTL = 2.hours

  def initialize(kb_id: nil, data_source_id: nil, tenant: nil)
    client_options = build_aws_client_options
    @client = Aws::BedrockAgent::Client.new(client_options)
    @data_source_id_override = data_source_id
    @tenant = tenant
    @kb_id = kb_id.presence ||
             (tenant&.bedrock_config&.knowledge_base_id if tenant&.respond_to?(:bedrock_config)) ||
             ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
             Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
  end

  # Returns which document names (from S3 list) are currently being indexed.
  # @return [Array<String>]
  def indexing_document_names
    info = cached_ingestion_info
    return [] if info.blank?

    job_id = info['job_id']
    filenames = info['indexing_docs'] || []
    return [] if job_id.blank? || filenames.empty?

    status = fetch_job_status(job_id)
    return [] unless status.in?(%w[STARTING IN_PROGRESS])

    filenames
  end

  # Registers an ingestion job and documents being indexed.
  # @param job_id [String]
  # @param document_names [Array<String>]
  def register_ingestion(job_id, document_names)
    return if job_id.blank?

    Rails.cache.write(
      CACHE_KEY,
      { 'job_id' => job_id, 'indexing_docs' => Array(document_names).compact.uniq },
      expires_in: CACHE_TTL
    )
  end

  # Returns current status of an ingestion job (for polling from jobs).
  # @return [String, nil] One of: STARTING, IN_PROGRESS, COMPLETE, FAILED, STOPPED
  def job_status(job_id)
    fetch_job_status(job_id)
  end

  # The configured data source, after it has been seen in this knowledge base.
  # Returns nil when that id is absent. Does not substitute another data source.
  def resolved_data_source_id
    find_data_source_id
  end

  # Returns failure reasons from a failed ingestion job (for user-facing messages).
  # @return [Array<String>] Empty if job succeeded or reasons unavailable

  def failure_reasons(job_id)
    ds_id = resolved_data_source_id
    return [] unless ds_id

    resp = @client.get_ingestion_job(
      knowledge_base_id: @kb_id,
      data_source_id: ds_id,
      ingestion_job_id: job_id
    )
    Array(resp.ingestion_job&.failure_reasons).compact
  rescue StandardError => e
    Rails.logger.error("IngestionStatusService: get_ingestion_job failed — #{e.message}")
    []
  end

  # Returns statistics for a completed ingestion job.
  # Useful for detecting re-ingestions beyond the files the app explicitly uploaded.
  # @return [Hash] keys: scanned, new_indexed, modified_indexed, deleted, failed
  def job_statistics(job_id)
    ds_id = resolved_data_source_id
    return {} unless ds_id

    resp  = @client.get_ingestion_job(
      knowledge_base_id: @kb_id,
      data_source_id:    ds_id,
      ingestion_job_id:  job_id
    )
    stats = resp.ingestion_job&.statistics
    return {} unless stats

    {
      scanned:          stats.number_of_documents_scanned.to_i,
      new_indexed:      stats.number_of_new_documents_indexed.to_i,
      modified_indexed: stats.number_of_modified_documents_indexed.to_i,
      deleted:          stats.number_of_documents_deleted.to_i,
      failed:           stats.number_of_documents_failed.to_i
    }
  rescue StandardError => e
    Rails.logger.error("IngestionStatusService.job_statistics failed: #{e.message}")
    {}
  end

  # Clears indexing state when job completes (call from polling or callback).
  def clear_when_complete(job_id)
    info = Rails.cache.read(CACHE_KEY)
    return unless info && info['job_id'] == job_id

    status = fetch_job_status(job_id)
    return unless status.in?(%w[COMPLETE FAILED STOPPED])

    Rails.cache.delete(CACHE_KEY)
  end

  private

  def cached_ingestion_info
    Rails.cache.read(CACHE_KEY) || {}
  end

  def fetch_job_status(job_id)
    ds_id = resolved_data_source_id
    return nil unless ds_id

    resp = @client.get_ingestion_job(
      knowledge_base_id: @kb_id,
      data_source_id: ds_id,
      ingestion_job_id: job_id
    )
    resp.ingestion_job&.status
  rescue StandardError => e
    Rails.logger.error("IngestionStatusService: get_ingestion_job failed — #{e.message}")
    nil
  end

  DATA_SOURCE_LIST_LIMIT = 10

  def find_data_source_id
    preferred_id = configured_data_source_id
    summaries = data_source_summaries

    if summaries.empty?
      if preferred_id
        Rails.logger.error("IngestionStatusService: knowledge base #{@kb_id} has no data sources; configured data source #{preferred_id} was not selected")
      end
      return nil
    end

    if preferred_id
      ds = summaries.find { |summary| summary.data_source_id == preferred_id }
      if ds
        Rails.logger.info("IngestionStatusService: Using configured data source — #{preferred_id}")
        return ds.data_source_id
      end

      Rails.logger.error("IngestionStatusService: configured data source #{preferred_id} is not listed in knowledge base #{@kb_id}; status was not read from another data source")
      return nil
    end

    summaries.first&.data_source_id
  rescue StandardError => e
    Rails.logger.error("IngestionStatusService: list_data_sources failed — #{e.message}")
    nil
  end

  def configured_data_source_id
    preferred_id = @data_source_id_override.presence
    preferred_id ||= @tenant&.bedrock_config&.data_source_id if @tenant&.respond_to?(:bedrock_config)
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

    raise "IngestionStatusService: data source list for #{@kb_id} did not finish"
  end
end
