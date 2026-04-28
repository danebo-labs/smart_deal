# frozen_string_literal: true

# Builds the numbered lists for the post-reset picker:
#   - :recent → TechnicianDocument for this session's identifier+channel
#               (`for_identifier(...).recent`), or global `.recent` when no
#               session. Capped at RECENT_LIMIT (=9) — the technician rarely
#               has more than a handful of recent docs in flight, so a single
#               screen is enough and `+`/`-` pagination is intentionally
#               disabled here.
#   - :all    → KbDocument (entire KB catalog), paginated by PAGE_SIZE (=20).
#               Catalogs grow into the hundreds; sending them all in a single
#               WhatsApp burst would chunk into many Twilio messages and force
#               the technician to scroll past dozens of rows before reaching
#               `0`/`inicio`. Pagination keeps every page on a single chunk
#               with the nav footer always visible.
#
# Per-page numbering (1..N) is by design: the technician types small numbers
# even when the catalog is in the thousands. The state object remembers the
# CURRENT page's `doc_ids` and the page index so `+`/`-` can fetch neighbors.
#
# Exposes .list (Page struct), .render (WhatsApp text block) and .seed_query
# (synthetic body injected into the normal :new_query RAG flow once the user
# picks a document).
module Rag
  class WhatsappDocumentPicker
    # Recent list cap — single page, no pagination. 9 keeps single-digit picks
    # without colliding with the word-only `inicio` shortcut, AND matches the
    # historical UX (technicians treat "recent" as a tiny working set).
    RECENT_LIMIT = 9
    # Catalog page size. Sized to fit a header + 20 numbered rows + nav footer
    # under the 1550-char Twilio chunk limit, even with long display names.
    PAGE_SIZE    = 20

    Item = Struct.new(:id, :label, keyword_init: true)
    Page = Struct.new(:items, :page, :total_pages, :total_count, keyword_init: true)

    class << self
      # @param source        [Symbol] :recent or :all
      # @param conv_session  [ConversationSession, nil] scopes :recent to this
      #   thread's identifier+channel; ignored for :all.
      # @param page          [Integer] 1-indexed page number. Always clamped
      #   into [1..total_pages]. For :recent the page is forced to 1 since
      #   that source is single-page by contract.
      # @return [Page] items + page metadata for the rendered slice. items is
      #   an Array<Item> with non-empty labels, preserving DB order.
      def list(source:, conv_session: nil, page: 1)
        case source.to_sym
        when :recent
          # Single-page contract — count and slice are bounded by RECENT_LIMIT
          # so `total_pages` is always 1 and `+`/`-` never appears.
          rel   = recent_relation(conv_session: conv_session).limit(RECENT_LIMIT)
          items = rel.map { |r| Item.new(id: r.id, label: label_for(r, source: :recent)) }
                     .reject { |i| i.label.blank? }
          Page.new(items: items, page: 1, total_pages: 1, total_count: items.size)
        when :all
          rel          = all_relation
          total_count  = rel.count
          total_pages  = total_count.zero? ? 1 : (total_count.to_f / PAGE_SIZE).ceil
          clamped_page = page.to_i.clamp(1, total_pages)
          offset       = (clamped_page - 1) * PAGE_SIZE
          items = rel.offset(offset).limit(PAGE_SIZE)
                     .map { |r| Item.new(id: r.id, label: label_for(r, source: :all)) }
                     .reject { |i| i.label.blank? }
          Page.new(items: items, page: clamped_page, total_pages: total_pages, total_count: total_count)
        else
          Page.new(items: [], page: 1, total_pages: 1, total_count: 0)
        end
      end

      # WhatsApp text block: header + numbered rows for THIS page + page
      # indicator (when paginated) + nav footer (`+`/`-` only when a
      # neighbour exists, then `0` back, then word-only home shortcut).
      #
      # Empty lists surface a localized placeholder so the user is never
      # confused by silence.
      #
      # @param page    [Page] result from .list
      # @param source  [Symbol] :recent or :all (for header copy)
      # @param locale  [Symbol]
      # @param origin  [Symbol,nil] Rag::WhatsappPostResetState::ORIGIN_* —
      #   when ORIGIN_FACETED_CACHED, "0" restores the cached faceted answer
      #   instead of going back to the source picker, and the back label
      #   hints at that contract ("volver al resultado").
      def render(page:, source:, locale:, origin: nil)
        I18n.with_locale(locale) do
          header_key = (source.to_sym == :recent) ? "rag.wa_post_reset_recent_header" : "rag.wa_post_reset_all_header"
          header     = I18n.t(header_key)
          back       = back_label_for(origin)
          # Home is rendered as a TYPED WORD (no digit prefix). Any digit
          # prefix here would collide with a list-pick — items can occupy
          # 1..PAGE_SIZE (=20), so no single/double digit ≤ PAGE_SIZE is
          # safe. Format: "<word> - <action>".
          home_word   = I18n.t("rag.wa_menu.home_label")
          home_action = I18n.t("rag.wa_post_reset_home_action_label")
          home_row    = "#{home_word} - #{home_action}"

          if page.items.empty?
            empty = I18n.t("rag.wa_post_reset_empty_list")
            return "#{header}\n#{empty}\n\n0 - #{back}\n#{home_row}"
          end

          lines = page.items.each_with_index.map { |it, idx| "#{idx + 1} - #{it.label}" }
          nav   = []
          if page.total_pages > 1
            nav << I18n.t("rag.wa_post_reset_page_indicator", current: page.page, total: page.total_pages)
          end
          if page.page < page.total_pages
            nav << "+ - #{I18n.t('rag.wa_post_reset_next_page_label')}"
          end
          if page.page > 1
            nav << "- - #{I18n.t('rag.wa_post_reset_prev_page_label')}"
          end
          nav << "0 - #{back}"
          nav << home_row
          "#{header}\n#{lines.join("\n")}\n\n#{nav.join("\n")}"
        end
      end

      # Synthetic body re-injected into perform_faceted's :new_query path once
      # the user picks a document by number. Uses the localized template
      # "Describe %{name}" so the prompt stays natural + grounded in the KB.
      def seed_query(source:, id:, locale:)
        record = fetch(source: source, id: id)
        return nil if record.nil?
        name = label_for(record, source: source.to_sym)
        return nil if name.blank?
        I18n.with_locale(locale) { I18n.t("rag.wa_post_reset_seed_query", name: name) }
      end

      def fetch(source:, id:)
        case source.to_sym
        when :recent then TechnicianDocument.find_by(id: id)
        when :all    then KbDocument.find_by(id: id)
        end
      end

      # Origin-aware back label so a tap on "0" reads as "return to where I
      # was" rather than the generic "back".
      def back_label_for(origin)
        if origin&.to_sym == Rag::WhatsappPostResetState::ORIGIN_FACETED_CACHED
          I18n.t(
            "rag.wa_post_reset_back_to_answer_label",
            default: I18n.t("rag.wa_post_reset_back_label", default: I18n.t("rag.wa_menu.back_label"))
          )
        else
          I18n.t("rag.wa_post_reset_back_label", default: I18n.t("rag.wa_menu.back_label"))
        end
      end

      def label_for(record, source:)
        case source
        when :recent
          label = record.canonical_name.to_s.strip
          return label if label.present?
          Array(record.aliases).first.to_s.strip.presence
        when :all
          label = record.display_name.to_s.strip
          return label if label.present?
          record.stem_from_s3_key.to_s.strip.presence
        end
      end

      private

      def recent_relation(conv_session:)
        if conv_session
          TechnicianDocument.for_identifier(conv_session.identifier, conv_session.channel).recent
        else
          TechnicianDocument.recent
        end
      end

      def all_relation
        KbDocument.order(Arel.sql("COALESCE(display_name, '')"), :created_at)
      end
    end
  end
end
