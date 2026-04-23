# frozen_string_literal: true

require "json"

# Decides whether an incoming WhatsApp message is a FOLLOW-UP to the cached
# faceted answer (serve from cache, 0 Bedrock tokens) or a NEW QUERY (invalidate
# + retrieve_and_generate). Cascade: deterministic → heuristic → Haiku-nano.
#
# Default-safe: when uncertain, route to :new_query (freshness beats savings).
# Contract consumed by [`SendWhatsappReplyJob`](app/jobs/send_whatsapp_reply_job.rb).
module Rag
  class WhatsappFollowupClassifier
    Decision = Struct.new(:route, :facet_key, :confidence, :reason, :matched_token, keyword_init: true)

    # Closed whitelist of user phrases mapped to existing facets. Only returns
    # :synonym_match when the facet is non-empty in cache.
    SYNONYM_MAP = {
      parametros: %w[voltaje voltage valor cuanto especificacion torque medida amperaje],
      riesgos:    %w[riesgo peligro safety seguridad cuidado hazard warning],
      detalle:    %w[como pasos procedimiento steps how detalle procedure],
      secciones:  %w[secciones sections topics temas indice]
    }.freeze

    # Strong intent-shift verbs/phrases. If present AND cached intent is not
    # :emergency → force :new_query (bypass nano).
    STRONG_INTENT_PHRASES = [
      /\b(como|cómo) diagnosticar\b/i, /\bpor qu[eé] falla\b/i,
      /\bprocedimiento de rescate\b/i, /\brescate\b/i, /\bemergencia\b/i,
      /\b(como|cómo) instalar\b/i, /\bmodernizar\b/i
    ].freeze

    # Deterministic menu/navigation tokens after normalize(). ES+EN.
    # Numeric aliases: 5 → redraw (regresar), 6 → reset (inicio). Kept in sync
    # with Rag::FacetedAnswer::NAV_BACK_N / NAV_HOME_N.
    MENU_TOKEN_RE = /\A(?:([1-6])|riesgos?|parametros?|secciones?|detalle|mas|menu|volver|regresar|nuevo|nueva|new|reset|inicio|start|home|resumen|ficha|overview|summary)\z/

    RESET_TOKENS       = %w[nuevo nueva new reset inicio start home 6].freeze
    MENU_REDRAW_TOKENS = %w[menu volver regresar resumen ficha overview summary 5].freeze

    FACET_ORDER = %i[riesgos parametros secciones detalle].freeze

    NANO_THRESHOLD = 0.75

    class << self
      # @return [Decision]
      def classify(message:, cached:, conv_session:, locale:)
        norm = normalize(message)

        # 0. Universal reset tokens — ack + invalidate, NO RAG call.
        return Decision.new(route: :reset_ack, reason: :user_reset, confidence: 1.0) if RESET_TOKENS.include?(norm)

        # 0b. Menu redraw tokens — re-render the first message from cache.
        if MENU_REDRAW_TOKENS.include?(norm) && cached.present?
          return Decision.new(route: :show_menu, reason: :menu_redraw, confidence: 1.0)
        end

        # 1. Cache empty + menu token → guided help message
        if cached.blank? && norm.match?(MENU_TOKEN_RE)
          return Decision.new(route: :no_context_help, reason: :menu_without_cache, confidence: 1.0)
        end
        return Decision.new(route: :new_query, reason: :no_cache, confidence: 1.0) if cached.blank?

        # 2. New entity detected distinct from cached entities → new_query
        if (decision = detect_new_entity(message, cached))
          return decision
        end

        # 3. Strong intent shift → new_query (unless cached intent is emergency already)
        if STRONG_INTENT_PHRASES.any? { |re| message.match?(re) } && cached[:intent].to_s != "emergency"
          return Decision.new(route: :new_query, reason: :strong_intent_shift, confidence: 1.0)
        end

        # 4. Deterministic menu token (number, keyword, alias)
        if (m = MENU_TOKEN_RE.match(norm))
          if (facet_key = resolve_menu_token(m, cached, norm))
            return Decision.new(route: :facet_hit, facet_key: facet_key, reason: :deterministic_token, confidence: 1.0)
          end
        end

        # 5. "mas" → last facet served from conversation_history
        if norm == "mas" && (last = last_facet_from_history(conv_session))
          return Decision.new(route: :facet_hit, facet_key: last, reason: :deterministic_mas_last_facet, confidence: 1.0)
        end

        # 6. Synonym dictionary → non-empty facet. Populates matched_token so
        # the renderer can hoist the relevant line (deterministic semantic
        # response: "¿y el voltaje?" answers the voltaje line first, then the
        # rest of the facet).
        SYNONYM_MAP.each do |facet_key, synonyms|
          hit = synonyms.find { |s| norm.include?(s) }
          next unless hit
          next if facet_empty_in_cache?(cached, facet_key)
          return Decision.new(
            route: :facet_hit, facet_key: facet_key,
            reason: :synonym_match, confidence: 0.95, matched_token: hit
          )
        end

        # 7. Defensive heuristic: long messages are almost certainly new queries
        return Decision.new(route: :new_query, reason: :message_too_long, confidence: 0.95) if message.to_s.length > 120

        # 8. Nano classifier (only if flag ON)
        if ENV.fetch("WA_NANO_CLASSIFIER_ENABLED", "true") == "true"
          nano = nano_classify(message, cached, locale)
          return nano if nano
        end

        Decision.new(route: :new_query, reason: :nano_disabled_fallback, confidence: 0.6)
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

      def detect_new_entity(message, cached)
        resolved = safe_resolve(message)
        return nil if resolved.blank?

        cached_entities = Array(cached.dig(:faceted, :entities)).map(&:to_s)
        new_entities    = resolved.map { |d| d.respond_to?(:display_name) ? d.display_name.to_s : d.to_s } - cached_entities
        return nil if new_entities.empty?

        Decision.new(route: :new_query, reason: :new_entity_detected, confidence: 1.0)
      end

      def safe_resolve(message)
        KbDocumentResolver.resolve(message)
      rescue StandardError => e
        Rails.logger.warn("[WA_CLASSIFIER] resolver_error=#{e.class}")
        []
      end

      # @param match [MatchData]
      # @param cached [Hash]
      # @param norm   [String]
      # @return [Symbol, nil]
      def resolve_menu_token(match, cached, norm)
        if (number = match[1]) && !number.empty?
          n = number.to_i
          # 5 → redraw, 6 → reset. Handled by steps 0/0b before reaching step 4;
          # returning nil here prevents a stray facet hit if ordering ever changes.
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

      # Lightweight LLM-based classifier. Returns Decision or nil on failure.
      def nano_classify(message, cached, locale)
        started = Time.current
        available = FACET_ORDER.reject { |k| facet_empty_in_cache?(cached, k) }
        prompt = nano_prompt(message, cached, available, locale)

        raw = AiProvider.new.query(prompt, max_tokens: 80, temperature: 0.0)
        json = extract_json(raw)
        latency_ms = ((Time.current - started) * 1000).to_i

        unless json
          Rails.logger.info("[WA_CLASSIFIER] nano=parse_error latency_ms=#{latency_ms}")
          return nil
        end

        route      = json["route"].to_s
        confidence = json["confidence"].to_f
        facet_key  = json["facet_key"].to_s.downcase.to_sym

        if route == "facet_hit" && confidence >= NANO_THRESHOLD && FACET_ORDER.include?(facet_key)
          if facet_empty_in_cache?(cached, facet_key)
            return fallback_for_empty_facet(cached, facet_key, latency_ms)
          end
          log_nano(:facet_hit, :nano_decision, confidence, latency_ms)
          return Decision.new(route: :facet_hit, facet_key: facet_key, confidence: confidence, reason: :nano_decision)
        end

        reason = confidence < NANO_THRESHOLD ? :nano_low_confidence_fallback : :nano_new_query
        log_nano(:new_query, reason, confidence, latency_ms)
        Decision.new(route: :new_query, confidence: confidence, reason: reason)
      rescue StandardError => e
        Rails.logger.warn("[WA_CLASSIFIER] nano_error=#{e.class} msg=#{e.message}")
        nil
      end

      def fallback_for_empty_facet(cached, requested_key, latency_ms)
        unless facet_empty_in_cache?(cached, :detalle)
          log_nano(:facet_hit, :empty_facet_fallback_detalle, 0.7, latency_ms)
          return Decision.new(route: :facet_hit, facet_key: :detalle, reason: :empty_facet_fallback_detalle, confidence: 0.7)
        end
        log_nano(:empty_facet_notice, :empty_facet_no_fallback, 1.0, latency_ms)
        Decision.new(route: :empty_facet_notice, facet_key: requested_key, reason: :empty_facet_no_fallback, confidence: 1.0)
      end

      def nano_prompt(message, cached, available, locale)
        <<~PROMPT.strip
          Decide if the new WhatsApp message is a FOLLOW-UP to the cached Q&A or a NEW QUERY.
          Locale: #{locale}
          Cached question: "#{cached[:question].to_s.truncate(160)}"
          Cached intent:   "#{cached[:intent]}"
          Available non-empty facets: #{available.join(', ')}
          New message: "#{message.to_s.truncate(160)}"
          Return ONLY one JSON line:
          {"route":"facet_hit|new_query","facet_key":"riesgos|parametros|secciones|detalle|null","confidence":0.0-1.0}
          Default to new_query when unsure. Threshold for facet_hit is 0.75.
        PROMPT
      end

      def extract_json(raw)
        return nil if raw.blank?
        str = raw.to_s[/\{.*\}/m]
        return nil if str.blank?
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def log_nano(route, reason, confidence, latency_ms)
        Rails.logger.info(
          "[WA_CLASSIFIER] route=#{route} reason=#{reason} confidence=#{format('%.2f', confidence)} latency_ms=#{latency_ms}"
        )
      end
    end
  end
end
