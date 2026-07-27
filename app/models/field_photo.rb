# frozen_string_literal: true

# Durable record of a technician's field photo: original bytes live in S3
# (field_photos/<account_id>/<sha256>/, outside bulk_chunks/ so Bedrock never
# indexes it); the thumbnail is small enough (~5 KB, 88px/Q70) to store inline
# and render as a data URL with zero extra round-trips. Never a KbDocument and
# never a Knowledge Base source — see docs/PRODUCT_ROADMAP.md Field-photo contract.
class FieldPhoto < ApplicationRecord
  belongs_to :account
  validates :sha256, :s3_key_original, :content_type, :byte_size, presence: true

  def thumbnail_data_url
    return nil if thumbnail_data.blank?

    "data:#{thumbnail_content_type.presence || 'image/jpeg'};base64,#{Base64.strict_encode64(thumbnail_data)}"
  end
end
