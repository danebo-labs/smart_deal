# frozen_string_literal: true

# Generates and persists a thumbnail for an image KbDocument by downloading
# the original from S3. Safe to call multiple times — exits early when a
# thumbnail already exists or the document is not an image.
class KbDocumentThumbnailFromS3
  IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .webp .gif].freeze

  def self.call(kb_doc)
    new(kb_doc).call
  end

  def initialize(kb_doc)
    @kb_doc = kb_doc
  end

  def call
    return unless image_extension?
    return if @kb_doc.thumbnail.present?

    blob = download_blob
    return if blob.blank?

    img = ImageCompressionService.compress_with_thumbnail(
      Base64.strict_encode64(blob),
      infer_content_type
    )
    KbDocumentThumbnailPersister.call(kb_doc: @kb_doc, img: img)
  rescue StandardError => e
    Rails.logger.warn("KbDocumentThumbnailFromS3: failed for kb_doc=#{@kb_doc.id} — #{e.message}")
  end

  private

  def image_extension?
    IMAGE_EXTENSIONS.include?(File.extname(@kb_doc.s3_key.to_s).downcase)
  end

  def infer_content_type
    case File.extname(@kb_doc.s3_key.to_s).downcase
    when ".png"  then "image/png"
    when ".webp" then "image/webp"
    when ".gif"  then "image/gif"
    else "image/jpeg"
    end
  end

  def download_blob
    s3 = S3DocumentsService.new
    key = KbDocument.object_key_for_match(@kb_doc.s3_key)
    s3.download(key)
  end
end
