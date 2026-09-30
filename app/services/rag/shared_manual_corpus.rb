# frozen_string_literal: true

module Rag
  # Ingestion still writes `manual_corpus=general` from this module
  # (`tag?` → `BatchResultsParserService#sidecar_metadata`). That attribute
  # is historical metadata. Retrieval authorization does not read it.
  # Open retrieval is the viewer's `account_id` plus `danebo_general` rows.
  # Legacy and Pilot slugs are not an approval.
  #
  # Scope of a new document, passed as `corpus_scope` to
  # `BatchResultsParserService#call`:
  # - `"general"` writes the attribute. It does not set knowledge_scope.
  # - `"account"` omits the attribute.
  # - omitted: manuals of the two slugs above still get the attribute; any
  #   other account does not. That default is not an approval.
  # Photos never receive the attribute.
  module SharedManualCorpus
    SLUGS = %w[danebo-legacy danebo-pilot-elevator].freeze
    ATTRIBUTE = "manual_corpus"
    GENERAL = "general"
    ACCOUNT = "account"
    SCOPES = [ GENERAL, ACCOUNT ].freeze
    PHOTO_INGESTION_PATH = "field_photo_v1"

    class << self
      def account_ids
        @account_ids ||= Account.where(slug: SLUGS).order(:id).pluck(:id).map(&:to_s).freeze
      end

      def reset_account_ids!
        @account_ids = nil
      end

      def member_id?(account_id)
        account_ids.include?(account_id.to_s)
      end

      def validate_scope!(corpus_scope)
        return if corpus_scope.nil? || corpus_scope.to_s.empty?
        return if SCOPES.include?(corpus_scope.to_s)

        raise ArgumentError, "corpus_scope must be \"general\" or \"account\""
      end

      def tag?(account_id:, ingestion_path:, corpus_scope: nil)
        return false if ingestion_path.to_s == PHOTO_INGESTION_PATH

        validate_scope!(corpus_scope)
        case corpus_scope.to_s
        when GENERAL then true
        when ACCOUNT then false
        else member_id?(account_id)
        end
      end
    end
  end
end
