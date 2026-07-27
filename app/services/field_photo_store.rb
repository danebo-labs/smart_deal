# frozen_string_literal: true

# Durable storage for a technician's field photo: original bytes in S3 under
# field_photos/ (outside bulk_chunks/, so Bedrock never indexes it) plus one row
# holding the thumbnail already produced by ImageCompressionService.
class FieldPhotoStore
  PREFIX = "field_photos"

  def self.persist!(account_id:, sha256:, binary:, content_type:, filename:,
                    thumbnail_binary: nil, thumbnail_content_type: nil,
                    thumbnail_width: nil, thumbnail_height: nil,
                    user_id: nil, conversation_session_id: nil)
    return nil if account_id.blank? || sha256.blank? || binary.blank?

    existing = FieldPhoto.find_by(account_id: account_id, sha256: sha256)
    return existing if existing

    key = object_key(account_id: account_id, sha256: sha256,
                     filename: filename, content_type: content_type)
    return nil unless S3DocumentsService.new.upload_binary(key, binary, content_type)

    FieldPhoto.create!(
      account_id: account_id, sha256: sha256, s3_key_original: key,
      content_type: content_type, byte_size: binary.bytesize,
      thumbnail_data: thumbnail_binary, thumbnail_content_type: thumbnail_content_type,
      thumbnail_width: thumbnail_width, thumbnail_height: thumbnail_height,
      user_id: user_id, conversation_session_id: conversation_session_id
    )
  rescue ActiveRecord::RecordNotUnique
    FieldPhoto.find_by(account_id: account_id, sha256: sha256)
  end

  # Rehydrates the original bytes so a re-ask can be re-analyzed after the
  # diagnosis cache TTL expired, without asking the technician to re-upload.
  def self.fetch_binary(field_photo)
    return nil if field_photo&.s3_key_original.blank?

    S3DocumentsService.new.download(field_photo.s3_key_original)
  end

  def self.object_key(account_id:, sha256:, filename:, content_type:)
    ext = File.extname(filename.to_s).delete_prefix(".").presence ||
      content_type.to_s.split("/").last.presence || "bin"
    "#{PREFIX}/#{account_id}/#{sha256}/original.#{ext}"
  end
  private_class_method :object_key
end
