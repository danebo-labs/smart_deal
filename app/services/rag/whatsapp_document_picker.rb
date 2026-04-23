# frozen_string_literal: true

# Builds the numbered lists for the post-reset picker:
#   - :recent → TechnicianDocument for this session's identifier+channel
#               (`for_identifier(...).recent`), or global `.recent` when no session
#   - :all    → KbDocument                 (entire KB catalog)
#
# Exposes .list (fetch + normalize), .render (WhatsApp-friendly text block)
# and .seed_query (synthetic body injected into the normal :new_query RAG
# flow once the user picks a document).
module Rag
  class WhatsappDocumentPicker
    MAX_ITEMS = 9  # single-digit picks keep typing minimal for field users.

    Item = Struct.new(:id, :label, keyword_init: true)

    class << self
      # @param conv_session [ConversationSession, nil] scopes :recent to this thread
      # @return [Array<Item>] non-empty-label items, preserving DB order.
      def list(source:, conv_session: nil)
        records =
          case source.to_sym
          when :recent
            rel =
              if conv_session
                TechnicianDocument.for_identifier(conv_session.identifier, conv_session.channel).recent
              else
                TechnicianDocument.recent
              end
            rel.limit(MAX_ITEMS)
          when :all
            KbDocument.order(Arel.sql("COALESCE(display_name, '')"), :created_at).limit(MAX_ITEMS)
          else
            []
          end

        records.map { |r| Item.new(id: r.id, label: label_for(r, source: source.to_sym)) }
               .reject { |i| i.label.blank? }
      end

      # WhatsApp text block with numbered rows and a trailing nav line
      # (0 = back to source list, 6 = full reset). Empty lists surface a
      # localized placeholder so the user is never confused by silence.
      def render(items:, source:, locale:)
        I18n.with_locale(locale) do
          header_key = (source.to_sym == :recent) ? "rag.wa_post_reset_recent_header" : "rag.wa_post_reset_all_header"
          header     = I18n.t(header_key)
          back       = I18n.t("rag.wa_post_reset_back_label", default: I18n.t("rag.wa_menu.back_label"))
          home       = I18n.t("rag.wa_menu.home_label")

          if items.empty?
            empty = I18n.t("rag.wa_post_reset_empty_list")
            return "#{header}\n#{empty}\n\n0 - #{back}\n6 - #{home}"
          end

          lines = items.each_with_index.map { |it, idx| "#{idx + 1} - #{it.label}" }
          nav   = [ "0 - #{back}", "6 - #{home}" ]
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
    end
  end
end
