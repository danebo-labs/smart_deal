# frozen_string_literal: true

# Turns a photo uploaded directly on the finding form — one multipart field,
# no separate screen (SafetyCulture pattern, plan section 2.3) — into a
# FieldPhoto the same way the chat's photo pipeline does: compress + thumbnail
# via ImageCompressionService, durable bytes via FieldPhotoStore. Reuses both
# services as-is; this class only adapts an uploaded file to their contract.
class InspectionFindingPhotoAttacher
  def self.call(uploaded_file, account_id:, user_id:)
    return nil if uploaded_file.blank? || account_id.blank?

    binary = uploaded_file.read
    return nil if binary.blank?

    sha256 = Digest::SHA256.hexdigest(binary)
    compressed = ImageCompressionService.compress_with_thumbnail(
      Base64.strict_encode64(binary),
      uploaded_file.content_type,
      filename: uploaded_file.original_filename
    )

    FieldPhotoStore.persist!(
      account_id: account_id,
      sha256: sha256,
      binary: compressed[:binary],
      content_type: compressed[:media_type],
      filename: uploaded_file.original_filename,
      thumbnail_binary: compressed[:thumbnail_binary],
      thumbnail_content_type: compressed[:thumbnail_content_type],
      thumbnail_width: compressed[:thumbnail_width],
      thumbnail_height: compressed[:thumbnail_height],
      user_id: user_id
    )
  rescue ImageCompressionService::CompressionError => e
    Rails.logger.warn("InspectionFindingPhotoAttacher: compression failed — #{e.message}")
    nil
  end
end
