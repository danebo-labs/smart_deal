# frozen_string_literal: true

module Rag
  # Read authority for one physical KbDocument.
  # Technical ranking and session focus do not pass through here.
  #
  # The owning account may use the row at its current knowledge_scope.
  # Any other account may use the row only when that scope is danebo_general.
  # An unknown scope is denied, including for the owner.
  class KnowledgeScopePolicy
    # Application budget for the general-URI arm. The Bedrock RetrievalFilter
    # API does not publish a maximum length for `in`. The limits this process
    # already enforces are one embedded logical operator, five clauses, and
    # depth 2. Above this budget the general arm is omitted: own documents
    # still match `account_id`, and no partial URI list is sent.
    OPEN_RETRIEVAL_MAX_GENERAL_URIS = 100
    OPEN_RETRIEVAL_MAX_URI_BYTES = 24_000

    OpenCorpus = Data.define(
      :viewer_account_id,
      :general_uris,
      :general_count,
      :candidate_count,
      :excluded_count,
      :over_limit,
      :denied_reason
    )

    Evidence = Data.define(:chunk, :status, :kb_document_id) do
      def authorized?
        status == :authorized
      end
    end

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

      # Foreign danebo_general rows whose canonical URI binds exactly one
      # physical row. The viewer's own rows are not listed: their chunks
      # already match account_id. An ambiguous or unmapped row is excluded.
      # Over the URI budget, general_uris is empty rather than truncated.
      def open_corpus(viewer_account:, uri_limit: OPEN_RETRIEVAL_MAX_GENERAL_URIS, byte_limit: OPEN_RETRIEVAL_MAX_URI_BYTES)
        viewer_id = viewer_account.respond_to?(:id) ? viewer_account&.id : viewer_account
        if viewer_id.blank?
          return OpenCorpus.new(
            viewer_account_id: nil, general_uris: [], general_count: 0,
            candidate_count: 0, excluded_count: 0, over_limit: false,
            denied_reason: "missing_viewer"
          )
        end

        foreign = KbDocument.danebo_general.where.not(account_id: viewer_id).to_a
        keys = foreign.flat_map { |row| lookup_keys(row.canonical_source) }.uniq
        related = keys.empty? ? [] : KbDocument.where(s3_key: keys).to_a
        grouped = related.group_by(&:canonical_source)

        uris = []
        excluded = 0
        foreign.each do |row|
          source = row.canonical_source
          hits = source && grouped[source]
          if source.nil? || hits.blank? || hits.size != 1 || hits.first.id != row.id
            excluded += 1
            next
          end

          uris << row.canonical_uri
        end
        uris.uniq!
        over = uris.size > uri_limit || uris.join.bytesize > byte_limit
        OpenCorpus.new(
          viewer_account_id: viewer_id.to_s,
          general_uris: over ? [] : uris,
          general_count: over ? 0 : uris.size,
          candidate_count: uris.size,
          excluded_count: excluded,
          over_limit: over,
          denied_reason: over ? "general_uris_over_limit" : nil
        )
      end

      # One query for the whole result set. A chunk is authorized only when
      # its URIs bind exactly one physical row and that row passes
      # authorized?. document_uid and chunk account_id confirm the row; they
      # are not a lookup key. Unmapped, ambiguous, and unauthorized chunks
      # are not authorized.
      def partition_evidence(chunks, viewer_account:)
        list = Array(chunks)
        return [] if list.empty?

        identities = list.map { |chunk| evidence_identity(chunk) }
        keys = identities.flat_map { |identity| identity[:sources].flat_map { |source| lookup_keys(source) } }.uniq
        rows = keys.empty? ? [] : KbDocument.where(s3_key: keys).to_a
        identities.map.with_index do |identity, index|
          decide_evidence(list[index], identity, rows, viewer_account)
        end
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

      def decide_evidence(chunk, identity, rows, viewer_account)
        matched = identity[:sources].filter_map do |source|
          hits = rows.select { |row| row.canonical_source == source }
          next if hits.empty?
          return evidence(chunk, :ambiguous) if hits.size != 1

          hits.first
        end.uniq
        return evidence(chunk, :unmapped) if matched.empty?
        return evidence(chunk, :ambiguous) if matched.size != 1

        row = matched.first
        return evidence(chunk, :ambiguous) if identity[:account_id] && row.account_id.to_s != identity[:account_id]
        return evidence(chunk, :ambiguous) if identity[:document_uid] && row.document_uid.to_s != identity[:document_uid]
        return evidence(chunk, :denied) unless authorized?(row, viewer_account: viewer_account)

        evidence(chunk, :authorized, row.id)
      end

      def evidence(chunk, status, kb_document_id = nil)
        Evidence.new(chunk: chunk, status: status, kb_document_id: kb_document_id)
      end

      def evidence_identity(chunk)
        metadata = evidence_metadata(chunk)
        sources = [
          metadata["original_source_uri"],
          metadata["x-amz-bedrock-kb-source-uri"],
          chunk_value(chunk, :original_source_uri),
          chunk_value(chunk, :bedrock_source_uri),
          chunk_value(chunk, :location_uri),
          evidence_location_uri(chunk)
        ].filter_map { |uri| KbDocument.canonical_source(uri) }.uniq

        {
          account_id: metadata["account_id"].to_s.presence,
          document_uid: (metadata["document_id"].presence || metadata["document_uid"].presence),
          sources: sources
        }
      end

      def evidence_metadata(chunk)
        raw = chunk_value(chunk, :metadata)
        raw = raw.to_h if raw.respond_to?(:to_h) && !raw.is_a?(Hash)
        raw.to_h.stringify_keys
      rescue StandardError
        {}
      end

      def evidence_location_uri(chunk)
        location = chunk_value(chunk, :location)
        return if location.nil?
        return location[:uri] || location["uri"] if location.is_a?(Hash)
        return location.s3_location&.uri if location.respond_to?(:s3_location)

        nil
      end

      def chunk_value(chunk, key)
        return chunk[key] || chunk[key.to_s] if chunk.is_a?(Hash)
        return chunk.public_send(key) if chunk.respond_to?(key)

        nil
      end
    end
  end
end
