# frozen_string_literal: true

# Transient per-WhatsApp-number state tracking the two-step post-reset picker
# (1=recientes / 2=existentes → list → pick document → seed query).
#
# Lives in Rails.cache (Solid Cache) with a short TTL (5 min). Invariants:
#   - Only written after :reset_ack (so it never collides with an active
#     faceted cache — the reset itself invalidated it).
#   - Cleared as soon as the user picks a document or 5 min pass.
#   - Shape stays flat + JSON-serialisable (phase/source/doc_ids) to survive
#     cache round-trips on dev + prod.
module Rag
  class WhatsappPostResetState
    KEY_PREFIX = "rag_wa_post_reset/v1"
    TTL        = 5.minutes

    # Valid values for :phase
    PHASE_PICKING_SOURCE    = :picking_source
    PHASE_PICKING_FROM_LIST = :picking_from_list

    class << self
      def key(whatsapp_to)
        "#{KEY_PREFIX}/#{whatsapp_to}"
      end

      def read(whatsapp_to)
        Rails.cache.read(key(whatsapp_to))
      end

      # @param phase   [Symbol] one of PHASE_*
      # @param source  [Symbol,nil] :recent or :all (set in phase 2 only)
      # @param doc_ids [Array<Integer>] ordered list of picked model ids
      def write(whatsapp_to, phase:, source: nil, doc_ids: [])
        payload = {
          phase:   phase.to_s,
          source:  source&.to_s,
          doc_ids: Array(doc_ids).map(&:to_i)
        }
        Rails.cache.write(key(whatsapp_to), payload, expires_in: TTL)
        Rails.logger.info("[WA_POST_RESET] to=#{whatsapp_to} op=write phase=#{phase} source=#{source} ids=#{payload[:doc_ids].length}")
        true
      end

      def clear(whatsapp_to)
        Rails.cache.delete(key(whatsapp_to))
      end

      def phase_of(state)
        return nil if state.blank?
        (state[:phase] || state["phase"]).to_s.to_sym
      end

      def source_of(state)
        return nil if state.blank?
        raw = state[:source] || state["source"]
        raw.present? ? raw.to_sym : nil
      end

      def doc_ids_of(state)
        Array(state[:doc_ids] || state["doc_ids"]).map(&:to_i)
      end
    end
  end
end
