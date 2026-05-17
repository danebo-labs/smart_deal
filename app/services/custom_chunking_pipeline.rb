# frozen_string_literal: true

# Orchestrates the web custom chunking path for all attachments in one request:
#   1. Upload each file to S3 (creates KbDocument).
#   2. Run SingleFileChunkingService per file (routes → chunks → writes to bulk DS S3 prefix).
#   3. Trigger BulkKbSyncService + BedrockIngestionJob to index via BEDROCK_BULK_DATA_SOURCE_ID.
#
# Fallback: any StandardError during steps 2–3 triggers the legacy KbSyncService path
# (OWRPGSX6XK) on the already-uploaded S3 files. The user never loses the upload.
#
# Called from QueryOrchestratorService#upload_and_sync_attachments when
# Rails.application.config.x.custom_chunking_web_enabled is true.
class CustomChunkingPipeline
  # @param images       [Array<Hash>] same shape as QOS @images
  # @param documents    [Array<Hash>] same shape as QOS @documents
  # @param conv_session [ConversationSession, nil]
  # @param tenant       [Tenant, nil]
  # @param locale       [String, nil] ISO 639-1 — forwarded to SingleFileChunkingService for image summary
  def initialize(images:, documents:, conv_session: nil, tenant: nil, locale: nil)
    @images         = Array(images)
    @documents      = Array(documents)
    @conv_session   = conv_session
    @tenant         = tenant
    @locale         = locale
    @uploaded_filenames = []
    @kb_document_ids    = []
    @web_v1_metadata    = []
  end

  # @return [Array<String>] successfully uploaded original filenames
  def run!
    s3 = S3DocumentsService.new

    upload_and_chunk_all(s3)

    return [] if @uploaded_filenames.empty?

    result = BulkKbSyncService.new.sync!(uploaded_filenames: @uploaded_filenames)
    if result.present?
      BedrockIngestionJob.perform_later(
        result[:job_id],
        @uploaded_filenames,
        kb_id:            result[:kb_id],
        data_source_id:   result[:data_source_id],
        conv_session_id:  @conv_session&.id,
        kb_document_ids:  @kb_document_ids,
        web_v1_metadata:  @web_v1_metadata
      )
    end

    @uploaded_filenames
  rescue StandardError => e
    if CustomChunkingNoFallbackTest.active?
      CustomChunkingNoFallbackTest.log_failure(
        e,
        uploaded_filenames: @uploaded_filenames,
        kb_document_ids:    @kb_document_ids
      )
      raise
    end

    if e.message.to_s.include?("credit balance")
      Rails.logger.warn(
        "[OPS] CustomChunking: Anthropic credit balance exhausted — " \
        "top up at console.anthropic.com/settings/plans. Falling back to legacy KB ingestion."
      )
    else
      Rails.logger.error("CustomChunking: fallback to OWRPGSX6XK — #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
    end
    fallback_to_legacy
    @uploaded_filenames
  end

  private

  def upload_and_chunk_all(s3)
    all_files = image_file_attrs + document_file_attrs

    all_files.each_with_index do |attrs, idx|
      upload_and_chunk_one(attrs, s3, idx)
    end
  end

  def image_file_attrs
    @images.each_with_index.map do |img, idx|
      ext          = img[:media_type]&.split("/")&.last || "jpeg"
      raw_filename = (img[:filename] || img["filename"]).presence
      raw_filename = File.basename(raw_filename) if raw_filename.present?
      filename     = raw_filename || "chat_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.#{ext}"
      binary       = img[:binary] || img["binary"] || Base64.decode64(img[:data] || img["data"])
      {
        filename:               filename,
        binary:                 binary,
        content_type:           img[:media_type] || img["media_type"] || "image/jpeg",
        thumbnail_binary:       img[:thumbnail_binary]       || img["thumbnail_binary"],
        thumbnail_content_type: img[:thumbnail_content_type] || img["thumbnail_content_type"],
        thumbnail_width:        img[:thumbnail_width]        || img["thumbnail_width"],
        thumbnail_height:       img[:thumbnail_height]       || img["thumbnail_height"]
      }
    end
  end

  def document_file_attrs
    @documents.each_with_index.map do |doc, idx|
      filename = (doc[:filename] || doc["filename"]).presence || "doc_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.txt"
      filename = File.basename(filename)
      binary   = Base64.decode64(doc[:data] || doc["data"])
      {
        filename:     filename,
        binary:       binary,
        content_type: doc[:media_type] || doc["media_type"] || "text/plain"
      }
    end
  end

  def upload_and_chunk_one(attrs, s3, _idx)
    filename     = attrs[:filename]
    binary       = attrs[:binary]
    content_type = attrs[:content_type]

    s3_key = s3.upload_file(filename, binary, content_type)
    return if s3_key.blank?

    sha256 = Digest::SHA256.hexdigest(binary)
    kb_doc = ensure_kb_document_for(s3_key)
    KbDocumentThumbnailPersister.call(kb_doc: kb_doc, img: attrs) if attrs[:thumbnail_binary].present?
    @kb_document_ids    << kb_doc.id
    @uploaded_filenames << filename

    chunk_asset = SingleFileChunkingService.new(
      binary:       binary,
      content_type: content_type,
      filename:     filename,
      s3_key:       s3_key,
      sha256:       sha256,
      locale:       @locale
    ).call

    @web_v1_metadata << {
      "filename"        => filename,
      "canonical_name"  => chunk_asset.canonical_name.to_s,
      "aliases"         => Array(chunk_asset.aliases),
      "summary"         => chunk_asset.summary.to_s.presence,
      "companion_offer" => chunk_asset.companion_offer.to_s.presence
    }
  end

  def ensure_kb_document_for(s3_key)
    KbDocument.find_or_create_by!(s3_key: s3_key) do |d|
      d.display_name = File.basename(s3_key, ".*").tr("_-", " ").strip.presence
      d.aliases      = []
    end
  rescue ActiveRecord::RecordNotUnique
    KbDocument.find_by!(s3_key: s3_key)
  end

  def fallback_to_legacy
    return if @uploaded_filenames.empty?

    result = KbSyncService.new(tenant: @tenant).sync!(uploaded_filenames: @uploaded_filenames)
    return if result.blank?

    BedrockIngestionJob.perform_later(
      result[:job_id],
      @uploaded_filenames,
      kb_id:           result[:kb_id],
      data_source_id:  result[:data_source_id],
      conv_session_id: @conv_session&.id,
      kb_document_ids: @kb_document_ids
    )
  rescue StandardError => e
    Rails.logger.error("CustomChunking: fallback also failed — #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    KbSyncBroadcaster.failed(filenames: @uploaded_filenames, message: e.message)
  end
end
