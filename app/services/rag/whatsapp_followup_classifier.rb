# frozen_string_literal: true

# Decides whether an incoming WhatsApp message is a NAVIGATION interaction
# with the cached faceted answer (serve from cache, 0 Bedrock tokens) or a
# CONTENT question (invalidate + retrieve_and_generate).
#
# SAFETY POLICY — closed allowlist (field elevator technicians):
#
#   The technician operates in field conditions: gloves, low light, small
#   screens, unreliable network. They write short messages, often without
#   question marks, verbs or full grammar (e.g. "voltaje componente",
#   "torque tornillo m8", "pasos cambio freno").
#
#   Heuristics that try to "guess intent" from such free text are unsafe in
#   this domain: a wrong cache hit would show OLD facet text as if it
#   answered a NEW question. In an elevator shaft that can hurt someone.
#
#   Therefore: ONLY messages that match a closed allowlist of navigation
#   tokens are served from cache. Anything else — including short keyword
#   queries that "sound like" a facet — falls through to RAG (anchored to
#   the KB, with fresh citations).
#
#   Trade-off: lower cache hit rate on free text, higher Bedrock cost. That
#   cost is intentional in this product: safety > token spend.
#
# Cascade (first match wins):
#   1. RESET_TOKENS                                → :reset_ack
#   2. MENU_REDRAW_TOKENS + cache present          → :show_menu
#   3. Cache empty + menu-shaped input             → :no_context_help
#   4. Cache empty + anything else                 → :new_query (no_cache)
#   5. Deterministic menu token (1-4 / facet word) → :facet_hit
#                                                  → :new_query if facet empty
#   6. "mas" + last facet inferable from history   → :facet_hit
#                                                  → :new_query if facet empty
#   7. Default                                     → :new_query (content_query)
#
# Contract consumed by [`SendWhatsappReplyJob`](app/jobs/send_whatsapp_reply_job.rb).
module Rag
  class WhatsappFollowupClassifier
    Decision = Struct.new(:route, :facet_key, :confidence, :reason, :matched_token, keyword_init: true)

    # Closed allowlist of navigation tokens. Anything outside this regex
    # falls through to :new_query. The check is on the FULLY normalized
    # token (no substring match), so "menu" inside a sentence like
    # "que opciones del menu hay" does NOT trigger menu redraw.
    MENU_TOKEN_RE = /\A(?:([1-6])|riesgos?|parametros?|secciones?|detalle|mas|menu|volver|regresar|nuevo|nueva|new|reset|inicio|start|home|resumen|ficha|overview|summary|back)\z/

    RESET_TOKENS       = %w[nuevo nueva new reset inicio start home 6].freeze
    MENU_REDRAW_TOKENS = %w[menu volver regresar resumen ficha overview summary back 5].freeze

    FACET_ORDER = %i[riesgos parametros secciones detalle].freeze

    class << self
      # @return [Decision]
      def classify(message:, cached:, conv_session:, locale:)
        norm = normalize(message)

        return Decision.new(route: :reset_ack, reason: :user_reset, confidence: 1.0) if RESET_TOKENS.include?(norm)

        if MENU_REDRAW_TOKENS.include?(norm) && cached.present?
          return Decision.new(route: :show_menu, reason: :menu_redraw, confidence: 1.0)
        end

        if cached.blank? && norm.match?(MENU_TOKEN_RE)
          return Decision.new(route: :no_context_help, reason: :menu_without_cache, confidence: 1.0)
        end
        return Decision.new(route: :new_query, reason: :no_cache, confidence: 1.0) if cached.blank?

        # Deterministic menu token (number 1-4 or exact facet word).
        # If the resolved facet is empty in cache, RE-RAG instead of showing
        # a "(—)" placeholder — the user explicitly asked for that data.
        if (m = MENU_TOKEN_RE.match(norm)) && (facet_key = resolve_menu_token(m, norm, cached))
          if facet_empty_in_cache?(cached, facet_key)
            return Decision.new(route: :new_query, reason: :empty_facet_reconsult, confidence: 1.0)
          end
          return Decision.new(route: :facet_hit, facet_key: facet_key, reason: :deterministic_token, confidence: 1.0)
        end

        if norm == "mas" && (last = last_facet_from_history(conv_session))
          if facet_empty_in_cache?(cached, last)
            return Decision.new(route: :new_query, reason: :empty_facet_reconsult, confidence: 1.0)
          end
          return Decision.new(route: :facet_hit, facet_key: last, reason: :deterministic_mas_last_facet, confidence: 1.0)
        end

        # Anything outside the navigation allowlist is a content question.
        # No nano, no synonym map, no length heuristics: anchor to KB.
        Decision.new(route: :new_query, reason: :content_query, confidence: 1.0)
      end

      # Normalize: NFD → strip accents → lowercase → strip → collapse spaces.
      def normalize(s)
        s.to_s
         .unicode_normalize(:nfd)
         .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
         .downcase.strip.gsub(/\s+/, " ")
      end

      def facet_empty_in_cache?(cached, facet_key)
        content = cached.dig(:faceted, :facets, facet_key.to_sym).to_s.strip
        content.empty? || content == "(—)" || content == "—"
      end

      # Returns the last facet served from the session's assistant turn, based
      # on the prefix we emit in Rag::FacetedAnswer#to_facet_message.
      # Nil when we can't infer it.
      def last_facet_from_history(conv_session)
        return nil if conv_session.nil?
        turns = conv_session.recent_history_for_prompt(turns: 4)
        last = turns.reverse.find { |h| h[:role].to_s == "assistant" }
        return nil if last.nil?
        case last[:content].to_s
        when /\A.{0,3}Riesgos/i                then :riesgos
        when /\A.{0,3}Par.{1,2}metros/i        then :parametros
        when /\A.{0,3}Secciones/i              then :secciones
        when /\A.{0,3}Detalle/i                then :detalle
        end
      end

      private

      # @param match [MatchData]
      # @param norm   [String]
      # @param cached [Hash]
      # @return [Symbol, nil]
      def resolve_menu_token(match, norm, cached)
        if (number = match[1]) && !number.empty?
          n = number.to_i
          # 5 → redraw, 6 → reset. Handled by earlier steps before reaching here;
          # returning nil prevents a stray facet hit if ordering ever changes.
          return nil if n > 4
          entry = Array(cached.dig(:faceted, :menu)).find { |m| m[:n].to_i == n || m["n"].to_i == n }
          key = (entry && (entry[:facet_key] || entry["facet_key"])).to_s
          return key.to_sym if FACET_ORDER.include?(key.to_sym)
          return nil
        end

        case norm
        when /\Ariesgos?\z/    then :riesgos
        when /\Aparametros?\z/ then :parametros
        when /\Asecciones?\z/  then :secciones
        when /\Adetalle\z/     then :detalle
        end
      end
    end
  end
end
