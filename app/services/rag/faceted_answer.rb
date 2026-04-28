# frozen_string_literal: true

require "json"

# Parses the Bedrock WhatsApp-channel output into a STRUCTURED answer:
#
#   [INTENT]
#   [DOCS]      JSON array of short doc names actually used in this answer
#   [RESUMEN]   compact body shown first
#   [RIESGOS]   PINNED safety block, ALWAYS present (slot #1 of the menu)
#   [SECCIONES] 3–5 sections, each "## <label> | <sources csv>" + body
#   [MENU]      "N | LABEL | KIND" (__riesgos__ | __sec_<n>__ | __new_query__)
#
# The delivery layer renders ONLY [RESUMEN] + the numbered menu first, then
# serves each section from cache when the technician taps a number — no extra
# Bedrock call. The class is intentionally forgiving: if the model drifts (no
# [DOCS], missing [RIESGOS], legacy facet labels, or no labels at all) it
# degrades to a safe fallback so we never deliver an empty WhatsApp bubble.
#
# Contract lives in BedrockRagService#whatsapp_delivery_channel_directive.
module Rag
  class FacetedAnswer
    KNOWN_INTENTS = %i[
      identification maintenance troubleshooting replacement installation
      modernization calibration emergency
    ].freeze

    EMPTY_MARKERS = [ "(—)", "—", "(-)", "(none)", "(ninguno)", "(ninguna)" ].freeze

    # Menu "kind" tokens emitted by the model in [MENU].
    KIND_RIESGOS     = :riesgos
    KIND_SECTION     = :section
    # Legacy — Haiku no longer emits this row; parser strips it on read.
    KIND_NEW_QUERY   = :new_query
    # Appended deterministically by the Rails layer AFTER Haiku's output.
    # Labels resolved at render time from i18n so they follow the message locale.
    KIND_LIST_RECENT = :list_recent
    KIND_LIST_ALL    = :list_all

    LABEL_MAP = {
      "INTENT"     => :intent,
      "DOCS"       => :docs,
      "RESUMEN"    => :resumen,
      "SUMMARY"    => :resumen,
      "RIESGOS"    => :riesgos,
      "RISKS"      => :riesgos,
      "SECCIONES"  => :secciones,
      "SECTIONS"   => :secciones,
      "MENU"       => :menu,
      # Legacy labels (pre dynamic-section refactor) — tolerated at parse time
      # so a stale prompt or a Haiku hiccup still yields a renderable answer.
      "PARÁMETROS" => :parametros_legacy,
      "PARAMETROS" => :parametros_legacy,
      "PARAMETERS" => :parametros_legacy,
      "DETALLE"    => :detalle_legacy,
      "DETAIL"     => :detalle_legacy
    }.freeze

    LABEL_PATTERN = /^\[(#{LABEL_MAP.keys.map { |k| Regexp.escape(k) }.join('|')})\](.*)$/i

    # "## <label> | <sources>" — section header inside [SECCIONES]
    SECTION_HEADER_PATTERN = /^##\s+(.+?)(?:\s*\|\s*(.+?))?\s*$/

    attr_reader :intent, :docs, :resumen, :riesgos, :sections, :menu, :raw

    # @param sections [Array<Hash>] [{ n:, key:, label:, sources: [String], body: String }]
    # @param menu     [Array<Hash>] [{ n:, label:, kind: Symbol, section_key: Symbol|nil }]
    # @param legacy   [Boolean] set by the fallback factory when Haiku emitted
    #   no structured labels at all (no [RESUMEN], no [SECCIONES], no [MENU]).
    #   The delivery layer inspects #legacy? to decide whether to fall back to
    #   the plain-text WhatsApp formatter.
    def initialize(intent:, docs: [], resumen: "", riesgos: "", sections: [], menu: [], raw: "", legacy: false)
      @intent   = intent
      @docs     = Array(docs)
      @resumen  = resumen.to_s
      @riesgos  = riesgos.to_s
      @sections = Array(sections)
      @menu     = Array(menu)
      @raw      = raw.to_s
      @legacy   = legacy
    end

    def self.parse(text)
      raw = text.to_s
      return fallback(raw) if raw.strip.empty?

      sections_raw = split_labels(raw)
      return fallback(raw) if sections_raw.empty? || sections_raw.keys == [ :_prelude ]

      intent   = parse_intent(sections_raw[:intent])
      docs     = parse_docs(sections_raw[:docs])
      resumen  = normalize_block(sections_raw[:resumen])
      riesgos  = normalize_block(sections_raw[:riesgos])
      sections = parse_sections(sections_raw[:secciones])

      # Legacy rescue: pre-refactor contract used [PARÁMETROS] / [DETALLE] +
      # [SECCIONES] as a flat navigation list. If we see those and no dynamic
      # sections, synthesize sections from the legacy blocks so the renderer
      # still produces a structured message.
      if sections.empty? && (sections_raw[:parametros_legacy] || sections_raw[:detalle_legacy])
        sections = synthesize_from_legacy(sections_raw)
      end

      menu = parse_menu(sections_raw[:menu], sections_count: sections.length)
      menu = append_list_options(menu) unless intent == :emergency

      new(
        intent:   intent,
        docs:     docs,
        resumen:  resumen,
        riesgos:  riesgos,
        sections: sections,
        menu:     menu,
        raw:      raw
      )
    end

    # Reconstruct from a cache hash produced by #to_cache_hash.
    def self.from_cache(cached)
      return fallback("") if cached.blank?

      data = cached.transform_keys(&:to_sym)
      sections = Array(data[:sections]).map do |s|
        h = s.transform_keys(&:to_sym)
        {
          n:       h[:n].to_i,
          key:     h[:key]&.to_sym,
          label:   h[:label].to_s,
          sources: Array(h[:sources]).map(&:to_s),
          body:    h[:body].to_s
        }
      end
      menu = Array(data[:menu]).map do |m|
        h = m.transform_keys(&:to_sym)
        {
          n:           h[:n].to_i,
          label:       h[:label].to_s,
          kind:        (h[:kind] || :section).to_sym,
          section_key: h[:section_key]&.to_sym
        }
      end

      new(
        intent:   (data[:intent] || :identification).to_sym,
        docs:     Array(data[:docs]).map(&:to_s),
        resumen:  data[:resumen].to_s,
        riesgos:  data[:riesgos].to_s,
        sections: sections,
        menu:     menu,
        raw:      data[:raw].to_s
      )
    end

    def to_cache_hash
      {
        intent:   intent,
        docs:     docs,
        resumen:  resumen,
        riesgos:  riesgos,
        sections: sections.map { |s| s.slice(:n, :key, :label, :sources, :body) },
        menu:     menu.map { |m| m.slice(:n, :label, :kind, :section_key) },
        raw:      raw
      }
    end

    # True when the parser did NOT find any structured labels and had to fall
    # back to wrapping the raw text into a single synthetic section — the
    # renderer MUST route these to the plain-text WhatsApp formatter instead.
    def legacy?
      @legacy || (resumen.strip.empty? && riesgos.strip.empty? && sections.empty? && menu.empty?)
    end

    def empty?
      resumen.strip.empty? && sections.empty?
    end

    # @param section_key [Symbol] :riesgos or :sec_<n>
    def section_empty?(section_key)
      return riesgos_empty? if section_key.to_sym == :riesgos
      section = find_section(section_key)
      return true if section.nil?
      body = section[:body].to_s.strip
      body.empty? || EMPTY_MARKERS.include?(body)
    end

    def riesgos_empty?
      body = riesgos.to_s.strip
      body.empty? || EMPTY_MARKERS.include?(body) || body.match?(/\A[—-]\s*sin riesgos/i)
    end

    def emergency?
      intent == :emergency
    end

    def find_section(section_key)
      return nil if section_key.blank?
      sections.find { |s| s[:key] == section_key.to_sym }
    end

    # First WhatsApp message: multi-doc banner (when applicable) + [RESUMEN] +
    # numbered menu. EMERGENCY stays menu-less. Legacy answers (model emitted
    # no structured labels) emit the raw text verbatim so callers that skip
    # the delivery-layer fallback still get something readable.
    # @return [String]
    def to_whatsapp_first_message(locale: :es)
      if legacy?
        return sections.first&.dig(:body).to_s.strip.presence || raw.to_s.strip
      end

      body = resumen.to_s.strip

      I18n.with_locale(locale) do
        banner = docs_banner
        pieces = [ banner, body ].compact_blank
        return pieces.join("\n\n") if emergency? || menu.empty?

        pieces << render_menu_block(locale: locale, full: true)
        pieces.compact_blank.join("\n\n")
      end
    end

    # Follow-up message for a tapped menu slot.
    # @param section_key [Symbol] :riesgos | :sec_<n>
    # @param locale      [Symbol]
    # @return [String]
    def to_section_message(section_key, locale: :es)
      key = section_key.to_sym

      if key == :riesgos
        return "" if riesgos_empty?
        return render_section(
          label:   I18n.with_locale(locale) { I18n.t("rag.wa_menu.default_labels.riesgos", default: "Riesgos") },
          sources: docs,
          body:    riesgos.to_s.strip,
          locale:  locale,
          exclude: :riesgos
        )
      end

      section = find_section(key)
      return "" if section.nil?
      return "" if section_empty?(key)

      render_section(
        label:   section[:label],
        sources: section[:sources],
        body:    section[:body].to_s.strip,
        locale:  locale,
        exclude: key
      )
    end

    private

    def render_section(label:, sources:, body:, locale:, exclude:)
      header = compose_section_header(label: label, sources: sources, locale: locale)
      footer = render_menu_block(locale: locale, full: false, exclude: exclude)
      [ "#{header}\n#{body}", footer ].compact_blank.join("\n\n")
    end

    # "*<Label> · <sources>*"  (compact); fallback to two lines when long.
    def compose_section_header(label:, sources:, locale:)
      label_clean = label.to_s.strip
      srcs = Array(sources).map(&:to_s).compact_blank
      return "*#{label_clean}*" if srcs.empty?

      joined = srcs.join(", ")
      combined = "*#{label_clean} · #{joined}*"
      return combined if combined.length <= 70

      I18n.with_locale(locale) do
        inline = I18n.t("rag.wa_section_header_inline", sources: joined,
                        default: "(fuentes: *#{joined}*)")
        "*#{label_clean}*\n#{inline}"
      end
    end

    def docs_banner
      return nil if docs.empty? || docs.size < 2
      I18n.t("rag.wa_docs_banner", docs: docs.join(", "), default: "📚 *Fuentes consultadas:* #{docs.join(', ')}")
    end

    # Renders the menu block as a vertical text-only list. Labels for the
    # appended file-listing slots (:list_recent / :list_all) are resolved here
    # so the message follows the current locale even when the cache was
    # written under a different one.
    #
    # A blank line is inserted right before the first file-listing slot so the
    # technician visually separates "answers about this query" (riesgos +
    # sections) from "switch context" actions (browse files).
    def render_menu_block(locale:, full:, exclude: nil)
      items =
        if full
          menu
        else
          menu.reject { |m| exclude && m[:section_key]&.to_sym == exclude.to_sym }
        end
      return "" if items.empty?

      I18n.with_locale(locale) do
        title = I18n.t("rag.wa_menu.title", default: "Opciones:")
        lines = []
        items.each_with_index do |m, idx|
          curr_kind = m[:kind]&.to_sym
          prev_kind = idx.positive? ? items[idx - 1][:kind]&.to_sym : nil
          if LIST_KINDS.include?(curr_kind) && LIST_KINDS.exclude?(prev_kind)
            lines << ""
          end
          lines << "#{m[:n]} - #{render_menu_label(m)}"
        end
        "#{title}\n#{lines.join("\n")}"
      end
    end

    LIST_KINDS = [ KIND_LIST_RECENT, KIND_LIST_ALL ].freeze
    private_constant :LIST_KINDS

    def render_menu_label(item)
      case item[:kind]&.to_sym
      when KIND_LIST_RECENT
        I18n.t("rag.wa_menu.list_recent_label", default: "Archivos recientes consultados")
      when KIND_LIST_ALL
        I18n.t("rag.wa_menu.list_all_label", default: "Todos los archivos")
      else
        strip_emoji(item[:label])
      end
    end

    def strip_emoji(label)
      label.to_s.gsub(/[^\w\sñáéíóúÑÁÉÍÓÚ·]/u, "").squeeze(" ").strip
    end

    class << self
      # Parses the raw text by label headers. Reuses the same tolerant approach
      # as before: labels can be "on their own line" or "label + inline value".
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

      # [DOCS] is expected as a JSON array. Falls back to a naive CSV split if
      # the model forgot the JSON wrapper (defensive).
      def parse_docs(block)
        return [] if block.blank?
        text = block.strip
        text = text.split("\n").first.to_s.strip if text.include?("\n")
        return [] if text.empty? || EMPTY_MARKERS.include?(text)

        parsed = safe_json_array(text)
        list =
          if parsed.is_a?(Array)
            parsed
          elsif text.start_with?("[")
            # Malformed JSON — strip brackets and split by commas.
            text.gsub(/\A\[|\]\z/, "").split(",")
          else
            text.split(",")
          end

        list.map { |s| s.to_s.strip.gsub(/\A["']|["']\z/, "").strip }
            .reject(&:empty?)
            .first(5)
            .map { |n| n[0, 40] }
      end

      def safe_json_array(text)
        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end

      # Parses 3–5 "## <label> | <sources csv>" sections + their bodies.
      def parse_sections(block)
        return [] if block.blank?
        lines = block.to_s.split("\n", -1)

        result = []
        current = nil
        lines.each do |line|
          if (m = line.match(SECTION_HEADER_PATTERN))
            result << current if current
            label   = m[1].to_s.strip
            sources = parse_sources_csv(m[2])
            current = { label: label, sources: sources, body: +"" }
          elsif current
            current[:body] << line << "\n"
          end
        end
        result << current if current

        result
          .map.with_index(1) do |sec, idx|
            {
              n:       idx,
              key:     :"sec_#{idx}",
              label:   sec[:label].to_s.strip,
              sources: Array(sec[:sources]).map(&:to_s),
              body:    normalize_block(sec[:body])
            }
          end
          .reject { |s| s[:label].empty? }
          .first(6) # hard cap; prompt asks ≤ 5 but we tolerate one over
      end

      def parse_sources_csv(csv)
        return [] if csv.blank?
        csv.split(",").map { |s| s.to_s.strip.gsub(/\A["']|["']\z/, "").strip }.reject(&:empty?)
      end

      # [MENU] items: "N | LABEL | __riesgos__|__sec_<n>__|__new_query__"
      # The parser still accepts legacy tokens (riesgos/parametros/secciones/
      # detalle) and maps them to :section so old prompts don't break rendering.
      def parse_menu(block, sections_count:)
        return [] if block.blank?
        lines = block.to_s.strip.split("\n").map(&:strip).reject(&:empty?)
        lines = lines.reject { |l| EMPTY_MARKERS.include?(l) }

        lines.filter_map { |line| parse_menu_line(line, sections_count: sections_count) }
      end

      # Returns a hash or nil. Kind is inferred from the 3rd pipe-separated
      # field; when absent, we default to :section except for the last row
      # (new_query) which we detect by keyword.
      def parse_menu_line(line, sections_count:)
        parts = line.split("|").map(&:strip)
        return nil if parts.empty?

        n = parts[0].to_s[/\A(\d+)/, 1].to_i
        return nil if n <= 0

        label     = parts[1].presence || parts[0]
        key_token = parts[2].to_s.downcase.strip

        kind, section_key = classify_menu_kind(key_token, label, n, sections_count)
        return nil if kind.nil?

        { n: n, label: label, kind: kind, section_key: section_key }
      end

      def classify_menu_kind(key_token, label, n, sections_count)
        case key_token
        when "__riesgos__", "riesgos", "risks"
          [ KIND_RIESGOS, :riesgos ]
        when "__new_query__", "new_query", "nueva_consulta", "nueva", "reset"
          [ KIND_NEW_QUERY, nil ]
        when /\A__sec_(\d+)__\z/
          idx = Regexp.last_match(1).to_i
          [ KIND_SECTION, :"sec_#{idx}" ]
        when "parametros", "parámetros", "parameters", "secciones", "sections", "detalle", "detail"
          # Legacy: map to sequential section slot based on position.
          [ KIND_SECTION, :"sec_#{[ n - 1, 1 ].max}" ]
        else
          # Unknown token + looks like the new_query position (last numeric slot).
          if label.to_s.match?(/nueva\s+consulta|new\s+query/i)
            [ KIND_NEW_QUERY, nil ]
          elsif label.to_s.match?(/riesgos|risks/i) && n == 1
            [ KIND_RIESGOS, :riesgos ]
          elsif n.between?(2, sections_count + 1)
            [ KIND_SECTION, :"sec_#{n - 1}" ]
          end
        end
      end

      # Strips any legacy "Nueva consulta" (__new_query__) row from Haiku's
      # output, then appends two file-listing slots so the technician can
      # always reach: their recent docs (technician_documents) or the full KB
      # catalog (kb_documents) without typing.
      #
      # Called from .parse only — .from_cache trusts the persisted shape, so a
      # cache written by an older deploy may lack list slots until its TTL
      # expires (acceptable: 30 min) or the cache version is bumped.
      def append_list_options(menu)
        cleaned = Array(menu).reject { |m| m[:kind]&.to_sym == KIND_NEW_QUERY }
        cleaned = cleaned.each_with_index.map { |m, idx| m.merge(n: idx + 1) }
        next_n  = cleaned.length + 1
        cleaned + [
          { n: next_n,     label: "list_recent", kind: KIND_LIST_RECENT, section_key: nil },
          { n: next_n + 1, label: "list_all",    kind: KIND_LIST_ALL,    section_key: nil }
        ]
      end

      # Converts legacy [PARÁMETROS]+[DETALLE] output to a single synthesized
      # section list so the structured renderer still works during rollout.
      def synthesize_from_legacy(raw)
        synthesized = []
        if raw[:parametros_legacy].to_s.strip.length.positive?
          synthesized << {
            n:       synthesized.length + 1,
            key:     :"sec_#{synthesized.length + 1}",
            label:   "Parámetros",
            sources: [],
            body:    normalize_block(raw[:parametros_legacy])
          }
        end
        if raw[:detalle_legacy].to_s.strip.length.positive?
          synthesized << {
            n:       synthesized.length + 1,
            key:     :"sec_#{synthesized.length + 1}",
            label:   "Detalle",
            sources: [],
            body:    normalize_block(raw[:detalle_legacy])
          }
        end
        synthesized
      end

      def normalize_block(content)
        return "" if content.nil?
        stripped = content.strip
        return "" if stripped.empty?
        stripped.gsub(/\n{3,}/, "\n\n")
      end

      def fallback(raw)
        body = raw.to_s.strip
        new(
          intent:   :identification,
          docs:     [],
          resumen:  "",
          riesgos:  "",
          sections: body.empty? ? [] : [ { n: 1, key: :sec_1, label: "Respuesta", sources: [], body: body } ],
          menu:     [],
          raw:      raw,
          legacy:   true
        )
      end
    end
  end
end
