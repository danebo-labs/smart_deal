# frozen_string_literal: true

module Rag
  # Read authority for one physical KbDocument.
  # Technical ranking and session focus do not pass through here.
  #
  # The owning account may use the row at its current knowledge_scope.
  # Any other account may use the row only when that scope is danebo_general.
  # An unknown scope is denied, including for the owner.
  class KnowledgeScopePolicy
    class << self
      def authorized?(kb_document, viewer_account:)
        scope_for(kb_document, viewer_account: viewer_account).present?
      end

      def scope_for(kb_document, viewer_account:)
        return nil if kb_document.nil? || viewer_account.nil?
        return nil unless KbDocument::KNOWLEDGE_SCOPES.include?(kb_document.knowledge_scope.to_s)
        return kb_document.knowledge_scope if owner?(kb_document, viewer_account)
        return kb_document.knowledge_scope if kb_document.knowledge_scope == KbDocument::KNOWLEDGE_SCOPE_GENERAL

        nil
      end

      # In memory. Callers preload the rows. This does not query.
      def scopes_for(kb_documents, viewer_account:)
        Array(kb_documents).each_with_object({}) do |document, scopes|
          scopes[document.id] = scope_for(document, viewer_account: viewer_account)
        end
      end

      RetrievalSet = Data.define(:status, :uris) do
        def denied?
          status == :deny
        end

        def allowed?
          status == :allow
        end
      end

      # The whole requested set. One denied or ambiguous URI denies every URI
      # in the set. Allowed URIs are the rows' canonical URIs.
      def authorize_retrieval_set(uris, viewer_account:)
        requested = Array(uris).map(&:to_s).compact_blank.uniq
        return RetrievalSet.new(status: :allow, uris: []) if requested.empty?
        return RetrievalSet.new(status: :deny, uris: []) if viewer_account.nil?

        identities = requested.map { |uri| KbDocument.canonical_source(uri) }
        return RetrievalSet.new(status: :deny, uris: []) if identities.any?(&:nil?)

        rows = rows_for_identities(identities)
        canonicals = []
        identities.each do |identity|
          matches = rows.select { |row| row.canonical_source == identity }
          return RetrievalSet.new(status: :deny, uris: []) unless matches.one?
          return RetrievalSet.new(status: :deny, uris: []) unless authorized?(matches.first, viewer_account: viewer_account)

          canonicals << matches.first.canonical_uri
        end
        RetrievalSet.new(status: :allow, uris: canonicals.uniq)
      end

      def authorized_retrieval_uris(uris, viewer_account:)
        decision = authorize_retrieval_set(uris, viewer_account: viewer_account)
        decision.allowed? ? decision.uris : []
      end

      # Scored catalog entry → the one physical row it names. document_uid is
      # not globally unique. The entry's canonical object and document_uid
      # must agree on exactly one row. Catalog account ids "1" and "3" are
      # index ids, not accounts.id, so they are not an account constraint.
      def bind_catalog_candidate(candidate, rows:, viewer_account:)
        uid = read_candidate(candidate, :document_id).to_s
        source = KbDocument.canonical_source(read_candidate(candidate, :s3_key))
        return nil if uid.blank? || source.nil? || viewer_account.nil?

        matches = Array(rows).select { |row| row.canonical_source == source }
        return nil unless matches.one?

        row = matches.first
        return nil unless row.document_uid.to_s == uid

        account_id = resolvable_catalog_account_id(read_candidate(candidate, :catalog_account_id))
        return nil if account_id && row.account_id.to_s != account_id
        return nil unless authorized?(row, viewer_account: viewer_account)

        row
      end

      def rows_for_catalog_candidates(candidates)
        list = Array(candidates)
        uids = list.map { |candidate| read_candidate(candidate, :document_id).to_s }.compact_blank.uniq
        keys = list.flat_map { |candidate| lookup_keys(KbDocument.canonical_source(read_candidate(candidate, :s3_key))) }.uniq
        relations = []
        relations << KbDocument.where(document_uid: uids) if uids.any?
        relations << KbDocument.where(s3_key: keys) if keys.any?
        return [] if relations.empty?

        relations.reduce { |combined, relation| combined.or(relation) }.to_a
      end

      def owner?(kb_document, viewer_account)
        viewer_id = viewer_account.respond_to?(:id) ? viewer_account.id : viewer_account
        return false if kb_document.nil? || kb_document.account_id.blank? || viewer_id.blank?

        kb_document.account_id.to_s == viewer_id.to_s
      end

      private

      def rows_for_identities(identities)
        keys = identities.flat_map { |identity| lookup_keys(identity) }.uniq
        return [] if keys.empty?

        KbDocument.where(s3_key: keys).to_a
      end

      def lookup_keys(identity)
        return [] if identity.nil?

        bucket, key = identity
        [ key, "s3://#{bucket}/#{key}" ]
      end

      def read_candidate(candidate, key)
        if candidate.is_a?(Hash)
          candidate[key] || candidate[key.to_s]
        elsif candidate.respond_to?(key)
          candidate.public_send(key)
        end
      end

      def resolvable_catalog_account_id(raw)
        id = raw.to_s
        return nil if id.blank?
        return nil if DocumentIdentityCatalog::GENERAL_ACCOUNT_IDS.include?(id)
        return nil unless Account.exists?(id: id)

        id
      end
    end
  end
end
