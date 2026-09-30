# frozen_string_literal: true

module Rag
  # Fixture/catalog comparison of the historical open OR against knowledge_scope.
  # It does not call Bedrock and it does not promote documents.
  class OpenRetrievalRecall
    Result = Data.define(
      :account_index, :document_id, :display_name, :historical, :current, :disposition
    )

    class << self
      def classify(entry, viewer_index:)
        data = entry.to_h.transform_keys(&:to_s)
        account_index = data["account_index"].to_s.presence || data["account_id"].to_s
        scope = data["knowledge_scope"].to_s.presence || KbDocument::KNOWLEDGE_SCOPE_PRIVATE
        manual_corpus = data["manual_corpus"].to_s
        viewer = viewer_index.to_s
        own = account_index == viewer
        historical = own || DocumentIdentityCatalog::GENERAL_ACCOUNT_IDS.include?(account_index) || manual_corpus == "general"
        current = own || scope == KbDocument::KNOWLEDGE_SCOPE_GENERAL
        Result.new(
          account_index: account_index,
          document_id: data["document_id"].to_s,
          display_name: data["display_name"].to_s,
          historical: historical,
          current: current,
          disposition: disposition(historical, current)
        )
      end

      def summarize(entries, viewer_index:)
        rows = Array(entries).map { |entry| classify(entry, viewer_index: viewer_index) }
        {
          "viewer_index" => viewer_index.to_s,
          "documents" => rows.size,
          "historical" => rows.count(&:historical),
          "current" => rows.count(&:current),
          "retained" => rows.count { |row| row.disposition == "retained" },
          "backfill_gap" => rows.count { |row| row.disposition == "backfill_gap" },
          "added_by_approval" => rows.count { |row| row.disposition == "added_by_approval" }
        }
      end

      private

      def disposition(historical, current)
        return "retained" if historical && current
        return "backfill_gap" if historical && !current
        return "added_by_approval" if current

        "out_of_corpus"
      end
    end
  end
end
