# frozen_string_literal: true

# Decides whether an incoming WhatsApp message is a NAVIGATION interaction
# with the cached structured answer (serve from cache, 0 Bedrock tokens) or a
# CONTENT question (invalidate + retrieve_and_generate).
#
# SAFETY POLICY — strict closed allowlist (field elevator technicians):
#
#   The technician operates in field conditions: gloves, low light, small
#   screens, unreliable network. They write short messages, often without
#   question marks, verbs or full grammar (e.g. "voltaje componente",
#   "torque tornillo m8", "pasos cambio freno").
#
#   Heuristics that try to "guess intent" from such free text are unsafe in
#   this domain: a wrong cache hit would show OLD section text as if it
#   answered a NEW question. In an elevator shaft that can hurt someone.
#
#   Therefore the recognised inputs are intentionally tiny:
#     - A digit that resolves against the cached menu (deterministic nav).
#     - The explicit reset tokens (RESET_PICKER_TOKENS / NEW_QUERY_TOKENS).
#   Everything else — including soft "redraw" words like "menu", "volver",
#   "regresar", or the "mas" shortcut that previous revisions accepted — is
#   treated as a content question and routed to RAG (cache invalidated).
#
#   The full menu is rendered as a footer on EVERY message (first answer +
#   each section view), so a "redraw" word is never necessary: the technician
#   always sees the numbered options.
#
#   Trade-off: lower cache hit rate on those grey-area words, higher Bedrock
#   cost on a handful of legacy tokens. That cost is intentional in this
#   product: safety + predictability > token spend.
#
# Cascade (first match wins):
#   1. RESET_PICKER_TOKENS (inicio/start/home)    → :reset_ack_with_picker
#   2. NEW_QUERY_TOKENS   (nuevo/nueva/new/reset) → :user_reset
#   3. Cache empty  + digit                       → :no_context_help
#   4. Cache empty  + anything else               → :new_query (no_cache)
#   5. Digit N resolves against cached[:structured][:menu]:
#        kind :riesgos     → :section_hit(:riesgos)
#        kind :section     → :section_hit(:sec_<k>)
#        kind :list_recent → :show_doc_list(source: :recent)
#        kind :list_all    → :show_doc_list(source: :all)
#        kind :new_query   → :user_reset (legacy cache compat)
#        section empty     → :new_query (:empty_section_reconsult)
#   6. Default                                    → :new_query (:content_query)
#
# Contract consumed by [`SendWhatsappReplyJob`](app/jobs/send_whatsapp_reply_job.rb).
module Rag
  class WhatsappFollowupClassifier
    Decision = Struct.new(:route, :section_key, :source, :confidence, :reason, :matched_token, keyword_init: true)

    # Tokens that force a hard reset ack + post-reset picker (kept separate
    # from plain "new query" so the existing UX — 1=recientes / 2=existentes —
    # stays reachable via a natural word).
    RESET_PICKER_TOKENS = %w[inicio start home].freeze

    # Lightweight reset (invalidate cache only; no picker).
    NEW_QUERY_TOKENS    = %w[nuevo nueva new reset].freeze

    class << self
      # @return [Decision]
      def classify(message:, cached:, conv_session:, locale:) # rubocop:disable Lint/UnusedMethodArgument
        norm = normalize(message)

        return Decision.new(route: :reset_ack_with_picker, reason: :user_reset_with_picker, confidence: 1.0) if RESET_PICKER_TOKENS.include?(norm)
        return Decision.new(route: :user_reset, reason: :user_reset, confidence: 1.0) if NEW_QUERY_TOKENS.include?(norm)

        if cached.blank?
          return Decision.new(route: :no_context_help, reason: :menu_without_cache, confidence: 1.0) if norm.match?(/\A\d+\z/)
          return Decision.new(route: :new_query, reason: :no_cache, confidence: 1.0)
        end

        # Digit → look up in cached structured menu.
        if norm.match?(/\A\d+\z/)
          n = norm.to_i
          entry = menu_entry_for(cached, n)
          if entry.nil?
            return Decision.new(route: :no_context_help, reason: :digit_out_of_range, confidence: 1.0)
          end

          case entry[:kind].to_sym
          when :new_query
            return Decision.new(route: :user_reset, reason: :user_reset, confidence: 1.0)
          when :list_recent
            return Decision.new(route: :show_doc_list, source: :recent, reason: :menu_list_recent, confidence: 1.0)
          when :list_all
            return Decision.new(route: :show_doc_list, source: :all, reason: :menu_list_all, confidence: 1.0)
          when :riesgos
            if section_empty_in_cache?(cached, :riesgos)
              return Decision.new(route: :new_query, reason: :empty_section_reconsult, section_key: :riesgos, confidence: 1.0)
            end
            return Decision.new(route: :section_hit, section_key: :riesgos, reason: :deterministic_digit, confidence: 1.0)
          when :section
            sk = entry[:section_key].to_sym
            if section_empty_in_cache?(cached, sk)
              return Decision.new(route: :new_query, reason: :empty_section_reconsult, section_key: sk, confidence: 1.0)
            end
            return Decision.new(route: :section_hit, section_key: sk, reason: :deterministic_digit, confidence: 1.0)
          end
        end

        # Anything outside the navigation allowlist is a content question.
        Decision.new(route: :new_query, reason: :content_query, confidence: 1.0)
      end

      # Normalize: NFD → strip accents → lowercase → strip → collapse spaces.
      def normalize(s)
        s.to_s
         .unicode_normalize(:nfd)
         .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
         .downcase.strip.gsub(/\s+/, " ")
      end

      # @param section_key [Symbol] :riesgos or :sec_<n>
      def section_empty_in_cache?(cached, section_key)
        structured = cached[:structured] || cached["structured"] || {}
        if section_key.to_sym == :riesgos
          body = (structured[:riesgos] || structured["riesgos"]).to_s.strip
          return true if body.empty?
          return true if %w[(—) — (-) (none) (ninguno) (ninguna)].include?(body)
          return true if body.match?(/\A[—-]\s*sin riesgos/i)
          return false
        end

        sections = Array(structured[:sections] || structured["sections"])
        section  = sections.find { |s| (s[:key] || s["key"]).to_s == section_key.to_s }
        return true if section.nil?
        body = (section[:body] || section["body"]).to_s.strip
        body.empty? || %w[(—) — (-)].include?(body)
      end

      private

      def menu_entry_for(cached, n)
        structured = cached[:structured] || cached["structured"] || {}
        menu = Array(structured[:menu] || structured["menu"])
        entry = menu.find { |m| (m[:n] || m["n"]).to_i == n }
        return nil if entry.nil?
        {
          n:           (entry[:n] || entry["n"]).to_i,
          label:       (entry[:label] || entry["label"]).to_s,
          kind:        (entry[:kind] || entry["kind"] || :section).to_sym,
          section_key: (entry[:section_key] || entry["section_key"])&.to_sym
        }
      end
    end
  end
end
