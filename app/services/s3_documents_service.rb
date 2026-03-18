# frozen_string_literal: true

# app/services/s3_documents_service.rb
require 'aws-sdk-s3'
require 'aws-sdk-bedrockagent'
require 'aws-sdk-core/static_token_provider'

class S3DocumentsService
  include AwsClientInitializer

  def initialize(bucket_name: nil)
    client_options = build_aws_client_options
    @s3 = Aws::S3::Client.new(client_options)
    @bucket_name = bucket_name.presence || find_bucket_name
  end

  # Returns array of document info hashes
  # @return [Array<Hash>] Array with keys: :name, :full_path, :size_mb, :size_bytes, :modified
  def list_documents
    return [] unless @bucket_name

    begin
      all_objects = []
      @s3.list_objects_v2(bucket: @bucket_name).each do |response|
        all_objects.concat(response.contents || [])
      end

      # Filter only real documents (exclude metadata, hidden files, directories)
      real_documents = all_objects.select do |obj|
        !obj.key.start_with?('.') &&
          obj.key.exclude?('$folder$') &&
          !obj.key.end_with?('/') &&
          obj.size > 1024 # At least 1KB
      end

      # Return array of document info
      real_documents.map do |obj|
        {
          name: obj.key.split('/').last, # Just filename
          full_path: obj.key,
          size_mb: (obj.size / 1.megabyte.to_f).round(2),
          size_bytes: obj.size,
          modified: obj.last_modified
        }
      end.sort_by { |doc| -doc[:size_bytes] } # Sort by size, largest first
    rescue StandardError => e
      Rails.logger.error("Error fetching S3 documents list: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      []
    end
  end

  # Uploads a file to the KB S3 bucket for future indexing.
  # Uses uploads/{date}/ so documents are organized by date. The data source has no inclusion
  # prefix configured, so the full bucket is indexed by Bedrock.
  # @param filename [String] The filename (e.g., "photo_20260215_123456.png")
  # @param binary_data [String] Raw binary content of the file
  # @param content_type [String] MIME type (e.g., "image/png")
  # @return [String, nil] The S3 key if successful, nil on failure
  def upload_file(filename, binary_data, content_type)
    return nil unless @bucket_name

    key = "uploads/#{Date.current.iso8601}/#{filename}"

    @s3.put_object(
      bucket: @bucket_name,
      key: key,
      body: binary_data,
      content_type: content_type
    )

    Rails.logger.info("S3 upload successful: s3://#{@bucket_name}/#{key}")
    key
  rescue StandardError => e
    Rails.logger.error("S3 upload failed: #{e.message}")
    nil
  end

  # Returns documents actually indexed (or being indexed/failed) in the Bedrock KB data source.
  # Paginates through all pages of list_knowledge_base_documents.
  #
  # @return [Array<Hash>] Array with keys: :name, :status (:indexed | :indexing | :failed), :updated_at
  def list_indexed_documents(kb_id: nil, data_source_id: nil)
    kb_id = resolve_kb_id(kb_id)
    return [] unless kb_id

    agent_client = Aws::BedrockAgent::Client.new(build_aws_client_options)
    data_source_id = resolve_data_source_id(agent_client, kb_id, data_source_id)
    return [] unless data_source_id

    documents = []
    next_token = nil

    loop do
      resp = agent_client.list_knowledge_base_documents(
        knowledge_base_id: kb_id,
        data_source_id: data_source_id,
        next_token: next_token
      )
      documents.concat(resp.document_details || [])
      next_token = resp.next_token
      break unless next_token
    end

    documents.filter_map do |doc|
      name = extract_document_name(doc)
      next unless name

      { name: name, status: map_kb_status(doc.status), updated_at: doc.updated_at }
    end
  rescue StandardError => e
    Rails.logger.error("S3DocumentsService#list_indexed_documents failed: #{e.message}")
    []
  end

  private

  def resolve_kb_id(kb_id)
    kb_id.presence ||
      ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
  end

  def resolve_data_source_id(agent_client, kb_id, data_source_id)
    return data_source_id if data_source_id.present?

    preferred = ENV.fetch('BEDROCK_DATA_SOURCE_ID', nil).presence ||
                Rails.application.credentials.dig(:bedrock, :data_source_id)
    return preferred if preferred.present?

    resp = agent_client.list_data_sources(knowledge_base_id: kb_id)
    resp.data_source_summaries.first&.data_source_id
  rescue StandardError => e
    Rails.logger.error("S3DocumentsService: list_data_sources failed — #{e.message}")
    nil
  end

  def extract_document_name(doc)
    uri = doc.identifier&.s3&.uri
    return nil if uri.blank?

    uri.split('/').last.presence
  end

  def map_kb_status(status)
    case status.to_s.upcase
    when 'INDEXED', 'METADATA_PARTIALLY_INDEXED'
      :indexed
    when 'INGESTION_IN_PROGRESS', 'PENDING'
      :indexing
    when 'FAILED', 'IGNORED'
      :failed
    else
      :indexed
    end
  end

  def find_bucket_name
    ENV['KNOWLEDGE_BASE_S3_BUCKET'] ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
      Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
      'document-chatbot-generic-tech-info'
  end
end
