# frozen_string_literal: true

# One-to-one BLOB thumbnail for image-type KbDocuments.
# Generated as an 88 px wide JPEG at the time of upload (single Vips pass alongside
# the main compressed image). Rendered as an inline data URL in the mobile docs panel
# so no extra HTTP round-trip is needed on flaky connectivity.
class KbDocumentThumbnail < ApplicationRecord
  belongs_to :kb_document

  validates :data,         presence: true
  validates :content_type, presence: true

  # Returns a data URL string suitable for use in <img src="...">.
  def data_url
    "data:#{content_type};base64,#{Base64.strict_encode64(data)}"
  end
end
