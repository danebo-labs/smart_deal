# frozen_string_literal: true

# Transient per-WhatsApp-number state tracking the two-step post-reset picker
# (1=recent / 2=all → list → pick document → seed query).
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

    # Valid values for :origin — tracks WHY the picker was armed so a "back"
    # tap can restore the right context:
    #   - :faceted_cached → user tapped __list_recent__ / __list_all__ from a
    #     LIVE faceted answer's menu; "0/back" should re-render that answer.
    #   - :reset_picker   → user came from the explicit reset flow (`inicio`);
    #     "0/back" returns to the source picker (current behavior).
    ORIGIN_FACETED_CACHED = :faceted_cached
    ORIGIN_RESET_PICKER   = :reset_picker

    class << self
      def key(whatsapp_to)
        "#{KEY_PREFIX}/#{whatsapp_to}"
      end

      def read(whatsapp_to)
        Rails.cache.read(key(whatsapp_to))
      end

      # @param phase   [Symbol] one of PHASE_*
      # @param source  [Symbol,nil] :recent or :all (set in phase 2 only)
      # @param doc_ids [Array<Integer>] ordered list of picked model ids for
      #   the CURRENT page only. `+`/`-` page nav re-fetches the neighbour
      #   page and overwrites this list.
      # @param origin  [Symbol,nil] one of ORIGIN_* — defaults to
      #   :reset_picker for backward-compat with payloads written before this
      #   field existed.
      # @param page    [Integer] 1-indexed page number for paginated sources
      #   (`:all`). Always 1 for `:recent` (single-page contract). Defaults
      #   to 1 so legacy callers stay backward-compatible.
      def write(whatsapp_to, phase:, source: nil, doc_ids: [], origin: ORIGIN_RESET_PICKER, page: 1)
        payload = {
          phase:   phase.to_s,
          source:  source&.to_s,
          doc_ids: Array(doc_ids).map(&:to_i),
          origin:  origin.to_s,
          page:    page.to_i
        }
        Rails.cache.write(key(whatsapp_to), payload, expires_in: TTL)
        Rails.logger.info("[WA_POST_RESET] to=#{whatsapp_to} op=write phase=#{phase} source=#{source} origin=#{origin} page=#{payload[:page]} ids=#{payload[:doc_ids].length}")
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

      # Defaults to :reset_picker so cache entries written before this field
      # existed keep their previous behavior (back → source picker).
      def origin_of(state)
        return ORIGIN_RESET_PICKER if state.blank?
        raw = state[:origin] || state["origin"]
        return ORIGIN_RESET_PICKER if raw.blank?
        raw.to_sym
      end

      # Defaults to 1 so legacy payloads (no :page field) keep working —
      # they were always single-page anyway under the old MAX_ITEMS=9 model.
      def page_of(state)
        return 1 if state.blank?
        raw = state[:page] || state["page"]
        page = raw.to_i
        page < 1 ? 1 : page
      end
    end
  end
end
