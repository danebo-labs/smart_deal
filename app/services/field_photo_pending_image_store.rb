# frozen_string_literal: true

# Short-lived transport between the web request and FieldPhotoAnalysisJob.
# Backed by shared Rails.cache so raw image bytes never enter Solid Queue args.
class FieldPhotoPendingImageStore
  class StoreError < StandardError; end

  class << self
    def write(binary:, content_type:, filename:, account_id:)
      raise ArgumentError, "binary is required" if binary.blank?

      token = SecureRandom.hex(16)
      payload = {
        binary: binary,
        content_type: content_type.to_s.presence || "image/jpeg",
        filename: File.basename(filename.to_s.presence || "photo"),
        account_id: account_id
      }
      written = Rails.cache.write(
        key(token: token, account_id: account_id),
        payload,
        expires_in: ttl
      )
      raise StoreError, "temporary image cache write failed" unless written

      token
    end

    def take(token:, account_id:)
      return nil if token.blank?

      cache_key = key(token: token, account_id: account_id)
      payload = Rails.cache.read(cache_key)
      Rails.cache.delete(cache_key)
      return nil unless payload.is_a?(Hash)

      value = payload.deep_symbolize_keys
      return nil unless value[:account_id].to_s == account_id.to_s
      return nil if value[:binary].blank?

      value.slice(:binary, :content_type, :filename, :account_id)
    rescue StandardError => e
      Rails.logger.warn(
        "FieldPhotoPendingImageStore take failed account=#{account_id || 'unattributed'} " \
        "token=#{token.to_s.first(8)} reason=#{e.class}"
      )
      nil
    end

    def delete(token:, account_id:)
      return false if token.blank?

      Rails.cache.delete(key(token: token, account_id: account_id))
    rescue StandardError => e
      Rails.logger.warn(
        "FieldPhotoPendingImageStore delete failed account=#{account_id || 'unattributed'} " \
        "token=#{token.to_s.first(8)} reason=#{e.class}"
      )
      false
    end

    def ttl
      ENV.fetch("PHOTO_PENDING_IMAGE_TTL_MINUTES", "10").to_f.minutes
    end

    private

    def key(token:, account_id:)
      "photo_pending/#{account_id.presence || 'unattributed'}/#{token}"
    end
  end
end
