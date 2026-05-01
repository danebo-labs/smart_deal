# frozen_string_literal: true

require "digest"

# Per-thread cache of the faceted WhatsApp answer so that menu follow-ups
# ("1", a risk-slot token, "voltage", etc.) can be served without re-invoking
# Bedrock. Backed by Rails.cache (Solid Cache in this app).
#
# Design decisions (see /Users/lahirisan/.cursor/plans/r2_wa_menu_followup_cache_9cca96f4.plan.md):
#   - ONE key per recipient ("whatsapp_to"). Drift from the live
#     ConversationSession entities is detected via :entity_signature stored
#     inside the value; on mismatch → invalidate + miss.
#   - HARD RULE: EMERGENCY intent is never cached (safety-critical info must
#     always be regenerated with fresh retrieval).
#   - Corrupt / legacy payloads are rescued and invalidated transparently.
module Rag
  class WhatsappAnswerCache
    TTL         = 30.minutes
    # Bumped v4 → v5 when the [MENU] structure changed: __new_query__ slot was
    # removed and two file-listing slots (__list_recent__, __list_all__) are
    # appended deterministically by Rag::FacetedAnswer at parse time. Old v4
    # caches still satisfy SCHEMA_KEYS but would render the old menu — the
    # version bump invalidates them cleanly.
    VERSION     = "v5"
    SCHEMA_KEYS = %i[
      question question_hash structured citations doc_refs locale
      entity_signature intent generated_at
    ].freeze

    class << self
      def key(whatsapp_to)
        "rag_wa_faceted/#{VERSION}/#{whatsapp_to}"
      end

      # @param whatsapp_to [String]
      # @param conv_session [ConversationSession, nil] if given, the entity
      #   signature stored in the cache value is compared against the live
      #   session; drift → invalidate + return nil.
      # @return [Hash, nil]
      def read(whatsapp_to, conv_session: nil)
        value = Rails.cache.read(key(whatsapp_to))
        return nil if value.blank?
        raise ArgumentError, "schema_drift" unless value.is_a?(Hash) && (SCHEMA_KEYS - value.keys).empty?

        # In MVP shared-session mode every tester mutates the same
        # active_entities set, so the signature drifts for reasons unrelated
        # to *this* recipient's cached answer. Per-number cache key already
        # isolates technicians; TTL (30 min) is enough freshness guard.
        if conv_session && !SharedSession::ENABLED &&
           value[:entity_signature] != entity_signature_for(conv_session)
          Rails.logger.info("[WA_CACHE] to=#{whatsapp_to} op=invalidate reason=entity_drift")
          invalidate(whatsapp_to)
          return nil
        end

        Rails.logger.info("[WA_CACHE] to=#{whatsapp_to} op=read hit=true age_s=#{Time.current.to_i - value[:generated_at].to_i}")
        value
      rescue StandardError => e
        Rails.logger.warn("[WA_CACHE] to=#{whatsapp_to} op=corrupt reason=#{e.class} msg=#{e.message}")
        invalidate(whatsapp_to)
        nil
      end

      # @param whatsapp_to [String]
      # @param value [Hash] must contain SCHEMA_KEYS (generated_at is filled in here).
      # @return [Boolean] false when skipped due to EMERGENCY intent.
      def write(whatsapp_to, value)
        if value[:intent].to_s == "emergency"
          Rails.logger.info("[WA_CACHE] to=#{whatsapp_to} op=skip_write reason=emergency")
          return false
        end

        payload = value.merge(generated_at: Time.current.to_i)
        Rails.cache.write(key(whatsapp_to), payload, expires_in: TTL)
        Rails.logger.info("[WA_CACHE] to=#{whatsapp_to} op=write intent=#{value[:intent]} ttl_s=#{TTL.to_i}")
        true
      end

      def invalidate(whatsapp_to)
        Rails.cache.delete(key(whatsapp_to))
      end

      # Stable 12-char signature of the sorted entity keys. Short because we
      # only need to detect drift, not identify entities.
      def entity_signature_for(conv_session)
        return "" if conv_session.nil?
        keys = conv_session.active_entities.keys.map(&:to_s).sort.join("|")
        Digest::SHA1.hexdigest(keys)[0, 12]
      end

      # Shortcut used by callers that just want the question hash for nano
      # classifier context or audit logs.
      def question_hash(question)
        Digest::SHA1.hexdigest(question.to_s.downcase.strip)[0, 16]
      end
    end
  end
end
