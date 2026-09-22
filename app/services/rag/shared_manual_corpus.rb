# frozen_string_literal: true

module Rag
  # Danebo (`danebo-legacy`) and the elevator pilot (`danebo-pilot-elevator`)
  # are general RAG knowledge. Every account's retrieve ORs those account ids,
  # already written on the indexed chunks, so no KB sync is required. It also
  # ORs `manual_corpus=general`, the mark written on later ingests.
  #
  # Scope of a new document, passed as `corpus_scope` to
  # `BatchResultsParserService#call`:
  # - `"general"` writes the attribute. Every account can retrieve it.
  # - `"account"` omits the attribute. Only that account_id matches.
  # - omitted: manuals of the two slugs above default to general; any other
  #   account defaults to account-only.
  # Photos never receive the attribute, and other accounts do not retrieve
  # them through the shared account ids (`ingestion_path` is excluded).
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
