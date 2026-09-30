# frozen_string_literal: true

module Rag
  # Open retrieval still reads the historical Legacy/Pilot manuals. A new
  # manual is not shared just because the uploader's account is one of
  # those slugs. `chunk_attribute` writes `manual_corpus=account` unless
  # the caller passes `corpus_scope: "general"` and that account has
  # `danebo_controlled`. The shared filter excludes `manual_corpus=account`.
  # Chunks indexed before that marker have no key; Bedrock `notEquals`
  # still matches a missing key, so the historical corpus stays readable.
  # Photos never receive the attribute. This is not pin authorization.
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

      # "general", "account", or nil for a photo. Slug membership is not a
      # share. An explicit general still requires accounts.danebo_controlled.
      def chunk_attribute(account_id:, ingestion_path:, corpus_scope: nil)
        return nil if ingestion_path.to_s == PHOTO_INGESTION_PATH

        validate_scope!(corpus_scope)
        if corpus_scope.to_s == GENERAL && controlled_account?(account_id)
          GENERAL
        else
          ACCOUNT
        end
      end

      def tag?(account_id:, ingestion_path:, corpus_scope: nil)
        chunk_attribute(
          account_id: account_id,
          ingestion_path: ingestion_path,
          corpus_scope: corpus_scope
        ) == GENERAL
      end

      def controlled_account?(account_id)
        return false if account_id.blank?

        Account.exists?(id: account_id, danebo_controlled: true)
      end
    end
  end
end
