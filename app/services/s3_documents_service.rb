# frozen_string_literal: true

# app/services/s3_documents_service.rb
require 'aws-sdk-s3'
require 'aws-sdk-core/static_token_provider'

class S3DocumentsService
  include AwsClientInitializer

  # Ciclo 5 H1/H2 (2026-08-04): any chunk body or `.metadata.json` sidecar
  # written directly under this prefix (initial ingestion, or a one-off
  # repair script like the 2026-08-03 canonical_name fix) must invalidate
  # Rag::SectionNeighborExpander's page index for that document — otherwise
  # a corrected sidecar/body can be shadowed by a stale Rails.cache entry
  # for up to INDEX_CACHE_TTL. Scoped to this prefix so #upload_binary's
  # other callers (field_photos/, document_manifests/) are unaffected.
  BULK_CHUNKS_PREFIX = "bulk_chunks/"

  attr_reader :bucket_name

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

  # Lists object keys under an explicit prefix, following pagination.
  # Unlike #list_documents this never scans the whole bucket.
  # @param prefix [String] e.g. "bulk_chunks/1/<uuid>/"
  # @return [Array<String>] object keys
  def list_keys(prefix:)
    return [] if @bucket_name.blank? || prefix.blank?

    keys = []
    resp = @s3.list_objects_v2(bucket: @bucket_name, prefix: prefix)
    loop do
      Array(resp.contents).each { |obj| keys << obj.key.to_s }
      break unless resp.is_truncated

      resp = @s3.list_objects_v2(
        bucket: @bucket_name, prefix: prefix, continuation_token: resp.next_continuation_token
      )
    end
    keys
  rescue StandardError => e
    Rails.logger.error("S3DocumentsService#list_keys failed for #{prefix}: #{e.message}")
    []
  end

  # Uploads a file to the KB S3 bucket for future indexing.
  # Uses uploads/{date}/ so originals are organized by date. The active Bedrock
  # data source indexes only app-generated text under bulk_chunks/.
  # @param filename [String] The filename (e.g., "photo_20260215_123456.png")
  # @param binary_data [String] Raw binary content of the file
  # @param content_type [String] MIME type (e.g., "image/png")
  # @return [String, nil] The S3 key if successful, nil on failure
  def upload_file(filename, binary_data, content_type, account_id: nil, document_uid: nil)
    return nil unless @bucket_name

    key = if account_id.present? && document_uid.present?
      ext = File.extname(filename.to_s).delete_prefix(".").presence || content_type.to_s.split("/").last.presence || "bin"
      "uploads/#{account_id}/#{document_uid}/original.#{ext}"
    else
      "uploads/#{Date.current.iso8601}/#{filename}"
    end

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

  # Writes a plain-text string to S3 at an explicit key (no prefix added).
  # Used by BatchResultsParserService to store pre-chunked .txt files under bulk_chunks/.
  # @param key [String] Full S3 key, e.g. "bulk_chunks/2026-05-07/abc123/chunk_0.txt"
  # @param content [String] UTF-8 text content
  # @return [String, nil] The key on success, nil on failure
  def upload_text(key, content)
    return nil unless @bucket_name

    @s3.put_object(
      bucket: @bucket_name,
      key: key,
      body: content,
      content_type: "text/plain; charset=utf-8"
    )
    invalidate_section_neighbor_cache(key)

    Rails.logger.info("S3 text upload: s3://#{@bucket_name}/#{key}")
    key
  rescue StandardError => e
    Rails.logger.error("S3 text upload failed: #{e.message}")
    nil
  end

  # Writes binary content at an explicit key with an explicit content type.
  # #upload_file computes its own uploads/ key; #upload_text forces text/plain.
  # @return [String, nil] the key on success, nil on failure
  def upload_binary(key, binary_data, content_type)
    return nil if @bucket_name.blank? || key.blank?

    @s3.put_object(
      bucket: @bucket_name, key: key, body: binary_data,
      content_type: content_type.presence || "application/octet-stream"
    )
    invalidate_section_neighbor_cache(key)
    key
  rescue StandardError => e
    Rails.logger.error("S3DocumentsService#upload_binary failed for #{key}: #{e.message}")
    nil
  end

  # Removes all objects under a prefix before a deterministic chunk rewrite.
  # Used by manual Batch ingestion so retries cannot leave stale chunks behind.
  # @param prefix [String] S3 prefix, e.g. "bulk_chunks/<sha>/<contract>"
  # @return [Integer] number of deleted objects
  def delete_prefix(prefix)
    return 0 unless @bucket_name

    deleted = 0
    @s3.list_objects_v2(bucket: @bucket_name, prefix: prefix).each do |response|
      objects = Array(response.contents).map { |obj| { key: obj.key } }
      next if objects.empty?

      @s3.delete_objects(
        bucket: @bucket_name,
        delete: { objects: objects, quiet: true }
      )
      deleted += objects.size
    end
    deleted
  rescue StandardError => e
    Rails.logger.error("S3 prefix delete failed for #{prefix}: #{e.message}")
    0
  end

  # Downloads an object from S3 and returns its raw binary.
  # @param key [String] S3 object key
  # @return [String, nil] raw bytes on success, nil on failure
  def download(key)
    return nil unless @bucket_name

    @s3.get_object(bucket: @bucket_name, key: key).body.read.force_encoding(Encoding::BINARY)
  rescue StandardError => e
    Rails.logger.error("S3DocumentsService#download failed for #{key}: #{e.message}")
    nil
  end

  private

  # Fires on every #upload_text/#upload_binary write under bulk_chunks/ —
  # initial ingestion and one-off repair scripts alike — so no future direct
  # S3 chunk fix can silently leave Rag::SectionNeighborExpander's page
  # index stale (ciclo 5 H1/H2, 2026-08-04: a corrected canonical_name sat
  # behind a 30-day cache for a full day because no script invalidated it).
  # Rails.cache.delete on a key that was never cached (e.g. a document still
  # mid-ingestion) is a harmless no-op — safe to call unconditionally.
  def invalidate_section_neighbor_cache(key)
    return unless key.to_s.start_with?(BULK_CHUNKS_PREFIX)

    prefix = key.rpartition("/").first
    return if prefix.blank?

    Rag::SectionNeighborExpander.invalidate!(prefix)
  end

  def find_bucket_name
    ENV['KNOWLEDGE_BASE_S3_BUCKET'] ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
      Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
      'document-chatbot-generic-tech-info'
  end
end
