# frozen_string_literal: true

module Rag
  # Reads the current session. A conflict is shown and the pin stays.
  # Nothing here writes active_entities, facts, or knowledge_scope.
  class FocusNotice
    Notice = Data.define(:message, :manufacturer)

    class << self
      def pin_conflict(session:, suggestion:)
        manufacturer = suggestion&.manufacturer.to_s
        return nil if manufacturer.blank? || session.nil?

        entries = conflicting_entries(session, manufacturer, suggestion.model_tokens)
        return nil if entries.empty?

        Notice.new(
          message: conflict_message(manufacturer, suggestion.model_tokens, entries),
          manufacturer: manufacturer
        )
      end

      def identity_conflict(session:)
        row = manufacturer_conflict(session)
        return nil unless row

        Notice.new(
          message: I18n.t("rag.identity_conflict", user: row["user"], photo: row["photo"]),
          manufacturer: nil
        )
      end

      private

      def conflicting_entries(session, manufacturer, model_tokens)
        documents = pinned_documents(session)
        return [] if documents.empty?

        catalog = Rag::DocumentIdentityCatalog.current
        documents.filter_map { |document|
          entry = catalog.for_document(document)
          entry if entry && conflicts?(entry, manufacturer, model_tokens)
        }
      end

      def pinned_documents(session)
        return [] unless session.respond_to?(:active_entities)

        ids = session.active_entities.values.filter_map { |meta|
          next unless meta.is_a?(Hash) && meta["source"] == "user_pin"

          meta["kb_document_id"].presence
        }
        return [] if ids.empty?

        KbDocument.where(id: ids).to_a
      end

      def conflicts?(entry, manufacturer, model_tokens)
        brands = Array(entry.brands).map { |brand| normalize(brand) }.compact_blank
        return false if brands.empty?
        return true if brands.exclude?(manufacturer)

        tokens = Array(model_tokens).map { |token| normalize(token) }.compact_blank
        designators = Array(entry.designators).map { |item| normalize(item) }.compact_blank
        return false if tokens.empty? || designators.empty?

        tokens.none? { |token| designators.include?(token) }
      end

      def conflict_message(manufacturer, model_tokens, entries)
        readable = readable_manufacturer(manufacturer)
        brands = entries.flat_map { |entry|
          Array(entry.brands).reject { |brand| normalize(brand) == manufacturer }
        }.compact_blank.uniq
        if brands.any?
          return I18n.t("rag.pin_conflict", manufacturer: readable, brand: brands.join(", "))
        end

        model = Array(model_tokens).compact_blank.uniq.join(", ")
        I18n.t("rag.pin_model_conflict", manufacturer: readable, model: model)
      end

      def manufacturer_conflict(session)
        return nil unless session.respond_to?(:active_episode)

        Array(session.active_episode.to_h["conflicts"]).find { |row|
          row.is_a?(Hash) &&
            row["fact"] == "manufacturer" &&
            row["user"].present? &&
            row["photo"].present?
        }
      end

      def readable_manufacturer(normalized)
        known = Rag::ActiveEpisodeTurn::MANUFACTURERS.find { |brand|
          normalize(brand) == normalized
        }
        return normalized unless known

        known.split.map(&:capitalize).join(" ")
      end

      def normalize(raw)
        Rag::FollowupQueryRewriter.normalize_label(raw)
      end
    end
  end
end
