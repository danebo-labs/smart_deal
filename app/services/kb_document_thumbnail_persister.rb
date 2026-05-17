# frozen_string_literal: true

# Persists a pre-rendered JPEG thumbnail (from ImageCompressionService#compress_with_thumbnail)
# onto a KbDocument. Idempotent; failures are logged and swallowed so uploads never abort.
class KbDocumentThumbnailPersister
  def self.call(kb_doc:, img:)
    new(kb_doc: kb_doc, img: img).call
  end

  def initialize(kb_doc:, img:)
    @kb_doc = kb_doc
    @img    = img
  end

  def call
    thumb_binary = @img[:thumbnail_binary] || @img["thumbnail_binary"]
    return if thumb_binary.blank?
    return if @kb_doc.thumbnail.present?

    @kb_doc.create_thumbnail!(
      data:         thumb_binary,
      content_type: @img[:thumbnail_content_type] || @img["thumbnail_content_type"] || "image/jpeg",
      width:        @img[:thumbnail_width] || @img["thumbnail_width"],
      height:       @img[:thumbnail_height] || @img["thumbnail_height"],
      byte_size:    thumb_binary.bytesize
    )
  rescue StandardError => e
    Rails.logger.warn("KbDocumentThumbnailPersister: thumbnail persist failed for kb_doc=#{@kb_doc.id} — #{e.message}")
  end
end
