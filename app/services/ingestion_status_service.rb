# frozen_string_literal: true

# app/services/ingestion_status_service.rb
#
# Tracks Knowledge Base ingestion job status to show which documents are
# currently being indexed vs already indexed.

require 'aws-sdk-bedrockagent'

class IngestionStatusService
  include AwsClientInitializer

  CACHE_KEY = 'kb_ingestion_info'
  CACHE_TTL = 2.hours

  def initialize(kb_id: nil)
    client_options = build_aws_client_options
    @client = Aws::BedrockAgent::Client.new(client_options)
    @kb_id = kb_id.presence ||
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
    ds_id = find_data_source_id
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

  def find_data_source_id
    ds_list = @client.list_data_sources(knowledge_base_id: @kb_id)
    ds_list.data_source_summaries.first&.data_source_id
  rescue StandardError => e
    Rails.logger.error("IngestionStatusService: list_data_sources failed — #{e.message}")
    nil
  end
end
