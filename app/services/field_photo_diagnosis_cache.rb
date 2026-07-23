# frozen_string_literal: true

# Account-scoped cache for live field-photo diagnoses. Values contain only the
# compact diagnosis and billing metadata; image bytes are never stored here.
class FieldPhotoDiagnosisCache
  SCHEMA_KEYS = %i[
    analysis compact_context canonical_name aliases manufacturer model_visible
    condition visible_codes model_id input_tokens output_tokens original_cost
    latency_ms created_at contract_version
  ].freeze

  class << self
    def key(account_id:, sha256:, locale:)
      "photo_dx/#{FieldPhotoPrompt::CONTRACT_VERSION}/#{account_key(account_id)}/#{sha256}/#{locale}"
    end

    def read(account_id:, sha256:, locale:)
      return nil unless enabled?

      value = Rails.cache.read(key(account_id: account_id, sha256: sha256, locale: locale))
      return nil if value.blank?

      payload = value.to_h.deep_symbolize_keys
      raise ArgumentError, "schema_drift" unless valid_payload?(payload)

      payload
    rescue StandardError => e
      Rails.logger.warn(
        "FieldPhotoDiagnosisCache read miss account=#{account_key(account_id)} " \
        "digest=#{sha256.to_s.first(12)} reason=#{e.class}"
      )
      invalidate(account_id: account_id, sha256: sha256, locale: locale)
      nil
    end

    def write(account_id:, sha256:, locale:, value:)
      return false unless enabled?

      payload = value.to_h.deep_symbolize_keys.slice(*SCHEMA_KEYS).merge(
        contract_version: FieldPhotoPrompt::CONTRACT_VERSION,
        created_at: value.to_h[:created_at] || value.to_h["created_at"] || Time.current.iso8601
      )
      raise ArgumentError, "invalid diagnosis cache payload" unless valid_payload?(payload)

      Rails.cache.write(
        key(account_id: account_id, sha256: sha256, locale: locale),
        payload,
        expires_in: ttl
      )
    rescue StandardError => e
      Rails.logger.warn(
        "FieldPhotoDiagnosisCache write skipped account=#{account_key(account_id)} " \
        "digest=#{sha256.to_s.first(12)} reason=#{e.class}"
      )
      false
    end

    def invalidate(account_id:, sha256:, locale:)
      Rails.cache.delete(key(account_id: account_id, sha256: sha256, locale: locale))
    rescue StandardError
      false
    end

    def ttl
      ENV.fetch("PHOTO_DIAGNOSIS_CACHE_TTL_HOURS", "24").to_f.hours
    end

    def enabled?
      ttl.positive?
    end

    private

    def valid_payload?(payload)
      return false unless payload.is_a?(Hash)
      return false unless (SCHEMA_KEYS - payload.keys).empty?
      return false unless payload[:contract_version] == FieldPhotoPrompt::CONTRACT_VERSION
      return false if payload[:analysis].blank? || payload[:compact_context].blank?
      return false unless payload[:aliases].is_a?(Array) && payload[:visible_codes].is_a?(Array)
      return false unless payload[:input_tokens].to_i.positive?
      return false if payload[:output_tokens].to_i.negative? || payload[:original_cost].to_f.negative?

      true
    end

    def account_key(account_id)
      account_id.presence || "unattributed"
    end
  end
end
