# frozen_string_literal: true

# Stores per-asset skip errors as i18n keys (JSON) and renders in the current UI locale.
class BulkUploadAssetErrorMessage
  LEGACY_UNSUPPORTED = /
    \AUnsupported\ file\ type\ '(?<mime>[^']+)'\ for\ (?<filename>.+)\.\ Allowed:\ (?<allowed>.+)\z
  /x

  LEGACY_OFFICE = /
    \AOffice\ conversion\ failed\ for\ (?<filename>.+):\ (?<detail>.+)\z
  /x

  def self.encode(key, params = {})
    { "k" => key, "p" => params.stringify_keys }.to_json
  end

  def self.display(stored)
    return if stored.blank?

    data = JSON.parse(stored)
    return stored unless data.is_a?(Hash) && data["k"].present?

    I18n.t(data["k"], **data.fetch("p", {}).symbolize_keys)
  rescue JSON::ParserError, TypeError
    legacy_display(stored)
  end

  def self.legacy_display(stored)
    if (m = stored.match(LEGACY_UNSUPPORTED))
      return I18n.t(
        "bulk_uploads.unsupported_file_type",
        mime:     m[:mime],
        filename: m[:filename],
        allowed:  m[:allowed]
      )
    end

    if (m = stored.match(LEGACY_OFFICE))
      return I18n.t(
        "bulk_uploads.office_conversion_failed",
        filename: m[:filename],
        detail:   m[:detail]
      )
    end

    stored
  end
end
