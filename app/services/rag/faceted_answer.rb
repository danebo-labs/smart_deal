# frozen_string_literal: true

# Parses the Bedrock WhatsApp-channel output into labeled facets so the
# delivery layer can show a short [RESUMEN] + [MENU] first, then serve
# [RIESGOS] / [PARÁMETROS] / [SECCIONES] / [DETALLE] on demand from cache
# without calling Bedrock again.
#
# Contract lives in BedrockRagService#whatsapp_delivery_channel_directive
# (OUTPUT STRUCTURE section of the WA delivery prompt).
#
# The parser is defensive: if the model ignores the labels entirely, the
# whole text becomes :detalle and the intent falls back to :identification
# — the caller gets a safe single-message delivery.
module Rag
  class FacetedAnswer
    KNOWN_INTENTS = %i[
      identification maintenance troubleshooting replacement installation
      modernization calibration emergency
    ].freeze

    FACET_KEYS = %i[resumen riesgos parametros secciones detalle].freeze

    # Reserved numeric slots for navigation options rendered after the facets.
    # Kept as constants so the classifier and the renderer agree on the mapping.
    NAV_BACK_N = 5
    NAV_HOME_N = 6

    EMPTY_MARKERS = [ "(—)", "—", "(-)", "(none)", "(ninguno)", "(ninguna)" ].freeze

    LABEL_MAP = {
      "INTENT"     => :intent,
      "RESUMEN"    => :resumen,
      "SUMMARY"    => :resumen,
      "RIESGOS"    => :riesgos,
      "RISKS"      => :riesgos,
      "PARÁMETROS" => :parametros,
      "PARAMETROS" => :parametros,
      "PARAMETERS" => :parametros,
      "SECCIONES"  => :secciones,
      "SECTIONS"   => :secciones,
      "DETALLE"    => :detalle,
      "DETAIL"     => :detalle,
      "MENU"       => :menu
    }.freeze

    LABEL_PATTERN = /^\[(#{LABEL_MAP.keys.map { |k| Regexp.escape(k) }.join('|')})\](.*)$/i

    attr_reader :intent, :facets, :menu, :raw

    # @param intent [Symbol]
    # @param facets [Hash<Symbol,String>] {resumen:, riesgos:, parametros:, secciones:, detalle:}
    # @param menu [Array<Hash>] [{n: Integer, label: String, facet_key: Symbol}]
    # @param raw [String]
    def initialize(intent:, facets:, menu:, raw:)
      @intent = intent
      @facets = facets
      @menu   = menu
      @raw    = raw
    end

    def self.parse(text)
      raw = text.to_s
      return fallback(raw) if raw.strip.empty?

      sections = split_labels(raw)

      # No labels at all → legacy single-answer; dump everything into :detalle
      return fallback(raw) if sections.empty? || sections.keys == [ :_prelude ]

      intent  = parse_intent(sections[:intent])
      facets  = FACET_KEYS.index_with do |key|
        normalize_block(sections[key])
      end
      menu    = parse_menu(sections[:menu])

      new(intent: intent, facets: facets, menu: menu, raw: raw)
    end

    # Reconstruct from a cache hash written by to_cache_hash.
    def self.from_cache(cached)
      return fallback("") if cached.blank?

      facets = (cached[:facets] || cached["facets"] || {}).transform_keys(&:to_sym)
      menu   = Array(cached[:menu] || cached["menu"]).map { |m| m.transform_keys(&:to_sym) }
      new(
        intent: (cached[:intent] || cached["intent"] || :identification).to_sym,
        facets: FACET_KEYS.index_with { |k| facets[k].to_s },
        menu:   menu,
        raw:    cached[:raw].to_s
      )
    end

    def to_cache_hash
      {
        intent: intent,
        facets: facets,
        menu:   menu,
        raw:    raw
      }
    end

    # True when the model did NOT emit any labels (fallback path).
    def legacy?
      intent == :identification && facets[:resumen].to_s.empty? && facets[:detalle].to_s.strip == raw.to_s.strip
    end

    def empty?
      FACET_KEYS.all? { |k| facets[k].to_s.strip.empty? }
    end

    def facet_empty?(key)
      content = facets[key.to_sym].to_s.strip
      content.empty? || EMPTY_MARKERS.include?(content)
    end

    def emergency?
      intent == :emergency
    end

    # First WhatsApp message: [RESUMEN] + menu (unless EMERGENCY, which emits
    # the full protocol inline and skips the menu). When document_label is
    # provided (from cache), prepends a "(fuente)" banner so the technician
    # always knows which document backs the answer.
    # @param locale [Symbol]
    # @param document_label [String, nil]
    # @return [String]
    def to_whatsapp_first_message(locale: :es, document_label: nil)
      body = facets[:resumen].to_s.strip
      body = facets[:detalle].to_s.strip if body.empty? # legacy fallback path

      prefix = document_source_prefix(document_label, locale: locale)
      body   = [ prefix, body ].reject(&:empty?).join("\n\n") if prefix

      return body if emergency? || menu.empty?

      [ body, render_menu_block(locale: locale, full: true) ].reject(&:empty?).join("\n\n")
    end

    # Follow-up message for a specific facet: labeled body + short menu footer.
    # @param facet_key [Symbol]
    # @param locale    [Symbol]
    # @param document_label [String, nil] rendered next to the header when short enough,
    #   else inlined under the header to preserve readability on small screens.
    # @param highlight [String, nil] term that triggered the route (e.g. "voltaje");
    #   when present, the first matching line is hoisted above the facet body with
    #   a 🔎 preamble, or an explicit "no documentado" notice if nothing matches.
    def to_facet_message(facet_key, locale: :es, document_label: nil, highlight: nil)
      key = facet_key.to_sym
      content = facets[key].to_s.strip
      return "" if content.empty? || EMPTY_MARKERS.include?(content)

      base_label = menu_label_for(key) || default_label_for(key, locale: locale)
      # Reduce emoji noise in facet headers: the technician already picked the
      # facet, so the icon is redundant and eats bubble real-estate.
      base_label = strip_emoji(base_label).strip
      header     = compose_header(base_label, document_label)
      body       = hoist_highlight(content, highlight, locale: locale)
      footer     = render_menu_block(locale: locale, full: false, exclude: key)

      [ "#{header}\n#{body}", footer ].reject(&:empty?).join("\n\n")
    end

    private

    # Renders the "Opciones:" block as a vertical text-only list (no emojis).
    # Always appends two navigation items as numbered rows after a blank line:
    #   5 - regresar   → redraw the first message (show_menu)
    #   6 - inicio     → hard reset + post-reset picker
    def render_menu_block(locale:, full:, exclude: nil)
      items = menu.reject { |m| exclude && m[:facet_key].to_sym == exclude.to_sym }
      return "" if items.empty?

      I18n.with_locale(locale) do
        title = I18n.t("rag.wa_menu.title", default: "Opciones:")
        back  = I18n.t("rag.wa_menu.back_label", default: "regresar")
        home  = I18n.t("rag.wa_menu.home_label", default: "inicio")
        lines = items.map { |m| "#{m[:n]} - #{strip_emoji(m[:label])}" }
        nav   = [ "#{NAV_BACK_N} - #{back}", "#{NAV_HOME_N} - #{home}" ]
        "#{title}\n#{lines.join("\n")}\n\n#{nav.join("\n")}"
      end
    end

    # Compact header with optional document label:
    #   short:  "*Riesgos · PCB Mainboard Orona*"
    #   long :  "*Riesgos*\n(del documento *PCB Mainboard Orona*)"
    def compose_header(label, document_label)
      return "*#{label}*" if document_label.blank?

      combined = "*#{label} · #{document_label}*"
      return combined if combined.length <= 55

      inline = I18n.t("rag.wa_doc_source_inline", doc: document_label,
                      default: "(from document *#{document_label}*)")
      "*#{label}*\n#{inline}"
    end

    def document_source_prefix(document_label, locale:)
      return nil if document_label.blank?
      I18n.with_locale(locale) do
        I18n.t("rag.wa_doc_source_prefix", doc: document_label,
               default: "*#{document_label}* (fuente)")
      end
    end

    # Deterministic semantic hoist. When classifier routed via :synonym_match,
    # it passes the matched token (e.g. "voltaje"). We search the cached facet
    # for a line containing it (accent/case-insensitive) and surface it first.
    # If none matches, emit an explicit "no documentado" notice so the user
    # doesn't read a generic block and assume the question was answered.
    def hoist_highlight(content, highlight, locale:)
      return content if highlight.blank?

      token      = normalize_token(highlight)
      return content if token.empty?

      lines      = content.split("\n")
      hit_line   = lines.find { |l| normalize_token(l).include?(token) }
      label      = highlight.to_s.strip.capitalize

      if hit_line
        preamble = "🔎 *#{label}*\n#{hit_line.strip}"
        rest     = (lines - [ hit_line ]).join("\n").strip
        rest.empty? ? preamble : "#{preamble}\n\n──────\n#{rest}"
      else
        I18n.with_locale(locale) do
          missing = I18n.t("rag.wa_missing_topic_in_facet", topic: label.downcase,
                           default: "No hay #{label.downcase} documentado en este archivo.")
          "🔎 *#{label}*\n⚠️ #{missing}\n\n──────\n#{content}"
        end
      end
    end

    def normalize_token(s)
      s.to_s
       .unicode_normalize(:nfd)
       .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
       .downcase.strip
    end

    def menu_label_for(facet_key)
      entry = menu.find { |m| m[:facet_key].to_sym == facet_key.to_sym }
      entry && entry[:label]
    end

    def default_label_for(facet_key, locale:)
      I18n.with_locale(locale) do
        I18n.t("rag.wa_menu.default_labels.#{facet_key}",
               default: facet_key.to_s.capitalize)
      end
    end

    def strip_emoji(label)
      label.to_s.gsub(/[^\w\sñáéíóúÑÁÉÍÓÚ·]/u, "").squeeze(" ").strip
    end

    class << self
      private

      # Splits the raw text by the label pattern. Returns a hash keyed by
      # facet symbol (plus :_prelude for anything before the first label).
      # Splits by label headers, tolerating both forms:
      #   [INTENT] EMERGENCY      ← value on same line (short enums)
      #   [RESUMEN]\n<body>       ← value on following lines (prose)
      # Returns a hash keyed by facet symbol (plus :_prelude for noise before
      # the first label).
      def split_labels(text)
        out       = { _prelude: +"" }
        current   = :_prelude
        text.each_line do |line|
          if (m = line.match(LABEL_PATTERN))
            key = LABEL_MAP[m[1].upcase] || LABEL_MAP[m[1]]
            current = key
            out[current] = +""
            inline = m[2].to_s.strip
            out[current] << inline << "\n" unless inline.empty?
            next
          end
          out[current] << line
        end
        out.delete(:_prelude) if out[:_prelude].to_s.strip.empty?
        out.delete(:_prelude) if out.keys.size > 1
        out
      end

      def parse_intent(raw_line)
        return :identification if raw_line.blank?
        token = raw_line.strip.downcase.split(/\s+/).first.to_s.gsub(/[^a-z_]/, "").to_sym
        KNOWN_INTENTS.include?(token) ? token : :identification
      end

      def parse_menu(block)
        return [] if block.blank?
        lines = block.to_s.strip.split("\n").map(&:strip).reject(&:empty?)
        lines = lines.reject { |l| EMPTY_MARKERS.include?(l) }
        lines.filter_map { |line| parse_menu_line(line) }
      end

      # Expected line format:  "1 | ⚠️ Riesgos | riesgos"
      # Fallback: tolerate missing facet_key by inferring from label.
      def parse_menu_line(line)
        parts = line.split("|").map(&:strip)
        return nil if parts.empty?
        n = parts[0].to_s[/\A(\d+)/, 1].to_i
        return nil if n <= 0

        label     = parts[1].presence || parts[0]
        key_token = parts[2].to_s.downcase.gsub(/[^a-z]/, "")
        facet_key = infer_facet_key(key_token.presence || label)
        { n: n, label: label, facet_key: facet_key }
      end

      def infer_facet_key(token)
        t = token.to_s.downcase
        return :riesgos    if t.include?("riesgo") || t.include?("risk")
        return :parametros if t.include?("paramet") || t.include?("spec")
        return :secciones  if t.include?("seccion") || t.include?("section")
        return :detalle    if t.include?("detalle") || t.include?("detail")
        :detalle
      end

      def normalize_block(content)
        return "" if content.nil?
        stripped = content.strip
        return "" if stripped.empty?
        # Collapse 3+ blank lines
        stripped.gsub(/\n{3,}/, "\n\n")
      end

      def fallback(raw)
        new(
          intent: :identification,
          facets: FACET_KEYS.index_with { |k| (k == :detalle ? raw.to_s.strip : "") },
          menu:   [],
          raw:    raw
        )
      end
    end
  end
end
