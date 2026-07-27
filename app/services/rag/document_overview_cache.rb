# frozen_string_literal: true

module Rag
  # Solid Cache-backed cache for the deterministic document overview (table of
  # contents) built by Rag::DocumentOverviewBuilder. Modeled on
  # Rag::WhatsappAnswerCache: versioned key, SCHEMA_KEYS validation, and
  # transparent invalidation on a corrupt/legacy payload.
  class DocumentOverviewCache
    VERSION     = "v1"
    TTL         = 30.days
    SCHEMA_KEYS = %i[sections chunk_count source generated_at].freeze

    class << self
      def key(account_id:, kb_document_id:)
        "document_overview/#{VERSION}/#{account_id}/#{kb_document_id}"
      end

      # @return [Hash, nil]
      def read(account_id:, kb_document_id:)
        cache_key = key(account_id: account_id, kb_document_id: kb_document_id)
        value = Rails.cache.read(cache_key)
        return nil if value.blank?
        raise ArgumentError, "schema_drift" unless value.is_a?(Hash) && (SCHEMA_KEYS - value.keys).empty?

        value
      rescue StandardError => e
        Rails.logger.warn("[DOCUMENT_OVERVIEW_CACHE] op=corrupt account_id=#{account_id} kb_document_id=#{kb_document_id} reason=#{e.class}")
        invalidate(account_id: account_id, kb_document_id: kb_document_id)
        nil
      end

      # Batched variant of #read for N documents in a single Solid Cache SELECT
      # (V4 — DocumentOverviewResponder must not do N x Rails.cache.read for N
      # pinned documents). Missing/corrupt entries are simply absent from the
      # result Hash — never raise, mirroring #read's fail-open behavior.
      # @return [Hash{Integer => Hash}] kb_document_id => cached value, hits only.
      def read_multi(account_id:, kb_document_ids:)
        ids = Array(kb_document_ids).uniq
        return {} if ids.empty?

        keys_by_id = ids.index_with { |id| key(account_id: account_id, kb_document_id: id) }
        raw = Rails.cache.read_multi(*keys_by_id.values)

        keys_by_id.each_with_object({}) do |(id, cache_key), result|
          value = raw[cache_key]
          next if value.blank?

          unless value.is_a?(Hash) && (SCHEMA_KEYS - value.keys).empty?
            Rails.logger.warn("[DOCUMENT_OVERVIEW_CACHE] op=corrupt account_id=#{account_id} kb_document_id=#{id} reason=schema_drift")
            invalidate(account_id: account_id, kb_document_id: id)
            next
          end

          result[id] = value
        end
      end

      # @param value [Hash] must contain SCHEMA_KEYS (generated_at is filled in here).
      def write(account_id:, kb_document_id:, value:)
        payload = value.merge(generated_at: Time.current.to_i)
        Rails.cache.write(
          key(account_id: account_id, kb_document_id: kb_document_id),
          payload,
          expires_in: TTL
        )
      end

      def invalidate(account_id:, kb_document_id:)
        Rails.cache.delete(key(account_id: account_id, kb_document_id: kb_document_id))
      end
    end
  end
end
