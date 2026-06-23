# frozen_string_literal: true

require "digest"

module Rag
  # Base for the deterministic answer paths (benchmark plan Fase 7).
  #
  # Flow: ONE Retrieve over the forced pinned scope → FieldRecordParser →
  # type selection → deterministic text. No LLM is invoked; action/result text
  # is emitted verbatim from the records — only the fixed presentation labels
  # are localized. An empty, incomplete, or invalid ledger fails safe with the
  # localized DATA_NOT_AVAILABLE message and a structured validation error.
  #
  # Scope rule (plan §16): a renderer runs only with a resolved pinned scope and
  # force_entity_filter — there is NO deterministic path against the global
  # catalog, and no record outside the filtered scope can feed an answer.
  class DeterministicRenderer
    # Deterministic answers read the COMPLETE forced pinned scope (Retrieve API
    # max), not a similarity sample: a checklist ledger that misses an indexed
    # record is wrong by construction. Measured on the v2 corpus, top-15/top-40
    # similarity sampling dropped documented test blocks (pit protection, tilt
    # sensor). This budget never reaches an LLM — cost is embedding-only — and
    # the renderer only runs with a forced pinned scope, so the result set is
    # bounded by the pinned documents, never the global catalog.
    FULL_SCOPE_CANDIDATES = 100

    # @return [DeterministicRenderer, nil] nil when the question does not match
    #   a deterministic intent or there is no forced pinned scope.
    def self.build(question:, entity_s3_uris:, entity_sources:, force_entity_filter:,
                   response_locale: nil, account: nil, rag_service: nil)
      return nil unless force_entity_filter && Array(entity_s3_uris).any?

      klass =
        if DeterministicIntent.exhaustive_functional_test_query?(question)
          FunctionalTestRenderer
        elsif DeterministicIntent.stop_work_checklist_query?(question)
          StopWorkRenderer
        end
      return nil unless klass

      klass.new(
        question: question,
        entity_s3_uris: Array(entity_s3_uris),
        entity_sources: Array(entity_sources),
        response_locale: response_locale,
        account: account,
        rag_service: rag_service
      )
    end

    def initialize(question:, entity_s3_uris:, entity_sources:, response_locale: nil,
                   account: nil, rag_service: nil)
      @question        = question
      @entity_s3_uris  = entity_s3_uris
      @entity_sources  = entity_sources
      @response_locale = response_locale
      @rag_service     = rag_service || BedrockRagService.new(account: account)
    end

    def execute
      retrieval = @rag_service.retrieve_chunks(
        @question,
        entity_s3_uris:      @entity_s3_uris,
        entity_sources:      @entity_sources,
        force_entity_filter: true,
        number_of_results:   number_of_results
      )
      chunks = retrieval[:chunks]
      ledger = FieldRecordParser.parse_chunks(chunks)

      validation = validate_ledger(ledger)
      if validation
        return failure_result(retrieval, ledger, validation)
      end

      rendered_records = select_records(ledger)
      if rendered_records.empty?
        return failure_result(retrieval, ledger, "no_applicable_records")
      end

      used_chunk_hashes = rendered_records.flat_map { |r| r.provenances.map { |p| p[:chunk_sha256] } }.uniq
      used_chunks = chunks.select { |c| used_chunk_hashes.include?(c[:chunk_sha256]) }

      {
        answer:              render(rendered_records),
        citations:           numbered_references(used_chunks),
        retrieved_citations: citation_shaped(used_chunks),
        doc_refs:            doc_refs(used_chunks),
        session_id:          nil,
        retrieval_trace:     retrieval[:retrieval_trace],
        generation_mode:     generation_mode,
        model_invoked:       false,
        parsed_record_ids:   ledger.record_ids.sort,
        rendered_record_ids: rendered_records.map(&:record_id).sort,
        record_counts_by_type: ledger.records.group_by(&:type).transform_values(&:size),
        record_ledger_sha256: ledger_sha256(ledger),
        retrieved_chunk_sha256s: chunks.pluck(:chunk_sha256),
        deterministic_validation: "ok"
      }
    end

    def generation_mode
      raise NotImplementedError
    end

    private

    # @return [String, nil] a failure reason, or nil when the ledger is usable.
    def validate_ledger(ledger)
      return "invalid_records: #{ledger.invalid_records.map(&:reason).uniq.join('; ')}" if ledger.invalid_records.any?
      return "conflicting_record_ids: #{ledger.conflicting_ids.join(', ')}" if ledger.conflicting_ids.any?
      return "empty_ledger" if ledger.records.empty?

      nil
    end

    def failure_result(retrieval, ledger, validation)
      Rails.logger.warn("#{self.class.name}: failing safe (#{validation})")
      {
        answer:              I18n.t("rag.pinned_no_results", locale: locale),
        citations:           [],
        retrieved_citations: [],
        doc_refs:            nil,
        session_id:          nil,
        retrieval_trace:     retrieval[:retrieval_trace],
        generation_mode:     generation_mode,
        model_invoked:       false,
        parsed_record_ids:   ledger.record_ids.sort,
        rendered_record_ids: [],
        record_counts_by_type: ledger.records.group_by(&:type).transform_values(&:size),
        record_ledger_sha256: ledger_sha256(ledger),
        retrieved_chunk_sha256s: Array(retrieval[:chunks]).pluck(:chunk_sha256),
        deterministic_validation: validation
      }
    end

    def ledger_sha256(ledger)
      Digest::SHA256.hexdigest(
        ledger.records.map { |r| "#{r.record_id}:#{r.content_fingerprint}" }.sort.join("\n")
      )
    end

    def locale
      (@response_locale.presence || I18n.locale).to_sym
    rescue StandardError
      :es
    end

    def label(key)
      I18n.t("rag.deterministic.#{key}", locale: locale)
    end

    # Chunk → the citation hash shape produced by Bedrock::CitationProcessor.
    def citation_shaped(chunks)
      chunks.map do |chunk|
        {
          content:  chunk[:content],
          location: { uri: chunk[:location_uri] },
          metadata: chunk[:metadata] || {}
        }
      end
    end

    def numbered_references(chunks)
      chunks.each_with_index.map do |chunk, index|
        source_uri = chunk[:original_source_uri] || chunk[:bedrock_source_uri]
        filename   = source_uri.to_s.split("/").last
        {
          number:   index + 1,
          title:    chunk.dig(:metadata, "canonical_name").presence || filename,
          filename: filename,
          content:  chunk[:content],
          location: { uri: chunk[:location_uri] },
          metadata: chunk[:metadata] || {}
        }
      end
    end

    def doc_refs(chunks)
      refs = chunks.group_by { |c| c[:original_source_uri] || c[:bedrock_source_uri] }
      result = refs.filter_map do |uri, group|
        next if uri.blank?

        metadata = group.first[:metadata] || {}
        {
          "source_uri"     => uri.to_s,
          "canonical_name" => metadata["canonical_name"].to_s.presence || uri.to_s.split("/").last,
          "aliases"        => [],
          "doc_type"       => "unknown"
        }
      end
      result.presence
    end
  end
end
