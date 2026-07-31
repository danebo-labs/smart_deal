# frozen_string_literal: true

module Rag
  # Live single-retrieve path for pinned, structured mapping questions.
  #
  # Flow: one tenant/document-filtered Retrieve → local section-neighbor repair
  # → one direct generation over the assembled evidence. Divider chunks are
  # replaced by an authorized same-section neighbor, so the generator receives
  # at most STRUCTURED_MAPPING_RESULTS chunks.
  class StructuredEvidenceRoute
    GENERATION_MODE = "structured_evidence_route"
    MAX_GENERATION_CHUNKS = Rag::EvidenceCandidateSelector::MAX_CONTEXTS
    SECTION_MARKER = Rag::EvidenceCandidateSelector::SECTION_MARKER
    HEADING_LINE = Rag::EvidenceCandidateSelector::HEADING_LINE

    # :answered    — one Retrieve, one generation, an answer. Terminal.
    # :abstained   — one Retrieve consumed, no usable answer. Terminal by design:
    #                falling through would bill a second Retrieve in the same turn.
    #                The text comes from Rag::AnswerSafetyProcessor's existing
    #                abstention, never from a new hardcoded string.
    # :unavailable — no Retrieve was consumed (ineligible, or Retrieve itself
    #                raised). The existing cascade may run.
    Outcome = Data.define(:status, :result)

    def self.build(question:, account:, entity_s3_uris:, entity_sources:, force_entity_filter:,
                   response_locale:, output_channel:, account_id: nil, user_id: nil,
                   conversation_session_id: nil, correlation_id: nil, rag_service: nil,
                   generator: nil, expander: nil)
      profile = RagRetrievalProfile.new(entity_sources: entity_sources, question: question)
      return nil unless eligible?(
        profile: profile,
        entity_s3_uris: entity_s3_uris,
        entity_sources: entity_sources,
        output_channel: output_channel
      )

      new(
        question: question,
        account: account,
        entity_s3_uris: entity_s3_uris,
        entity_sources: entity_sources,
        force_entity_filter: force_entity_filter,
        response_locale: response_locale,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        rag_service: rag_service,
        generator: generator,
        expander: expander
      )
    end

    def self.eligible?(profile:, entity_s3_uris:, entity_sources:, output_channel:)
      Rag::StructuredEvidenceRouteFlag.enabled? &&
        output_channel.to_sym == :web &&
        Array(entity_s3_uris).any? &&
        Array(entity_sources).include?("document") &&
        profile.structured_mapping_query? &&
        !profile.safety_critical_query? &&
        !profile.exhaustive_query?
    rescue NoMethodError
      false
    end
    private_class_method :eligible?

    def initialize(question:, account:, entity_s3_uris:, entity_sources:, force_entity_filter:,
                   response_locale:, account_id: nil, user_id: nil,
                   conversation_session_id: nil, correlation_id: nil, rag_service: nil,
                   generator: nil, expander: nil)
      @question = question.to_s
      @account = account
      @entity_s3_uris = Array(entity_s3_uris)
      @entity_sources = Array(entity_sources)
      @force_entity_filter = force_entity_filter
      @response_locale = response_locale
      @account_id = account_id || account&.id
      @user_id = user_id
      @conversation_session_id = conversation_session_id
      @correlation_id = correlation_id.presence || "query:#{SecureRandom.uuid}"
      @rag_service = rag_service || BedrockRagService.new(account: account)
      @generator = generator || AiProvider.new
      @expander = expander || Rag::SectionNeighborExpander.new
      @citation_processor = Bedrock::CitationProcessor.new
    end

    def execute
      retrieval_consumed = false
      retrieval = nil
      retrieval_ms = 0
      expansion_ms = 0
      local_before_generation_ms = 0
      generation_ms = 0
      expanded_chunks = []
      expansions = []
      chunks = []
      prompt = nil
      raw_answer = nil

      retrieval_started = monotonic_now
      retrieval = @rag_service.retrieve_chunks(
        @question,
        entity_s3_uris: @entity_s3_uris,
        entity_sources: @entity_sources,
        force_entity_filter: @force_entity_filter,
        number_of_results: RagRetrievalProfile::STRUCTURED_MAPPING_RESULTS,
        account_id: @account_id,
        correlation_id: @correlation_id
      )
      retrieval_consumed = true
      retrieval_ms = elapsed_ms(retrieval_started)

      expansion_started = monotonic_now
      expanded_chunks, expansions = expand_dividers(retrieval[:chunks])
      expansion_ms = elapsed_ms(expansion_started)
      if expanded_chunks.empty?
        return abstained_outcome(
          reason: :empty_evidence,
          retrieval: retrieval,
          retrieval_ms: retrieval_ms,
          expansion_ms: expansion_ms,
          expanded_chunks: expanded_chunks,
          chunks: chunks,
          expansions: expansions
        )
      end

      local_started = monotonic_now
      chunks = select_generation_chunks(expanded_chunks)
      citation_evidence = citation_shaped(chunks)
      prompt = generation_prompt(chunks)
      local_before_generation_ms = elapsed_ms(local_started)

      generation_started = monotonic_now
      raw_answer = @generator.query(
        prompt,
        max_tokens: BedrockRagService::DEFAULT_RAG_CONFIG[:generation_max_tokens],
        temperature: BedrockRagService::DEFAULT_RAG_CONFIG[:generation_temperature]
      ).to_s.strip
      generation_ms = elapsed_ms(generation_started)
      if raw_answer.blank?
        return abstained_outcome(
          reason: :generation_failure,
          retrieval: retrieval,
          retrieval_ms: retrieval_ms,
          expansion_ms: expansion_ms,
          local_ms: local_before_generation_ms,
          generation_ms: generation_ms,
          expanded_chunks: expanded_chunks,
          chunks: chunks,
          expansions: expansions,
          prompt: prompt,
          raw_answer: raw_answer,
          model_invoked: true
        )
      end

      local_after_generation_started = monotonic_now
      internal_answer = BedrockRagService.allocate.send(
        :normalize_absence_semantics,
        raw_answer,
        question: @question,
        locale: locale
      )
      answer = Rag::AnswerSafetyProcessor.new(locale: locale).call(
        internal_answer,
        evidence: citation_evidence,
        require_cited_evidence: true
      )
      citations = @citation_processor.build_numbered_references(
        citation_evidence,
        answer,
        question: @question
      )
      local_ms = local_before_generation_ms + elapsed_ms(local_after_generation_started)
      unless valid_citations?(answer, citations, chunks.size)
        return abstained_outcome(
          reason: :citation_failure,
          retrieval: retrieval,
          retrieval_ms: retrieval_ms,
          expansion_ms: expansion_ms,
          local_ms: local_ms,
          generation_ms: generation_ms,
          expanded_chunks: expanded_chunks,
          chunks: chunks,
          expansions: expansions,
          prompt: prompt,
          raw_answer: raw_answer,
          model_invoked: true
        )
      end

      trace = structured_trace(
        retrieval: retrieval,
        retrieval_ms: retrieval_ms,
        expansion_ms: expansion_ms,
        local_ms: local_ms,
        generation_ms: generation_ms,
        chunks: chunks,
        expansions: expansions
      )

      log_route(
        expansions: expansions,
        timings: trace[:structured_route],
        answer: answer,
        outcome: :answered,
        prompt: prompt,
        raw_answer: raw_answer
      )

      result = {
        answer: answer,
        citations: citations,
        retrieved_citations: citation_evidence,
        doc_refs: doc_refs(chunks),
        retrieval_trace: trace,
        session_id: nil,
        generation_mode: GENERATION_MODE,
        model_invoked: true,
        retrieved_chunk_sha256s: chunks.pluck(:chunk_sha256),
        correlation_id: @correlation_id,
        diagnostics: {
          raw_answer: raw_answer,
          internal_answer: internal_answer,
          retrieved_chunks: expanded_chunks,
          generation_chunks: chunks,
          safety_evidence_chunks: citation_evidence,
          expansions: expansions
        }
      }
      Outcome.new(status: :answered, result: result)
    rescue BedrockRagService::BedrockServiceError => e
      Rails.logger.warn("Rag::StructuredEvidenceRoute: AWS path failed — #{e.message}")
      return Outcome.new(status: :unavailable, result: nil) unless retrieval_consumed

      abstained_outcome(
        reason: :generation_failure,
        retrieval: retrieval,
        retrieval_ms: retrieval_ms,
        expansion_ms: expansion_ms,
        local_ms: local_before_generation_ms,
        generation_ms: generation_ms,
        expanded_chunks: expanded_chunks,
        chunks: chunks,
        expansions: expansions,
        prompt: prompt,
        raw_answer: raw_answer,
        model_invoked: prompt.present?
      )
    rescue StandardError => e
      Rails.logger.warn("Rag::StructuredEvidenceRoute: failed — #{e.class}: #{e.message}")
      return Outcome.new(status: :unavailable, result: nil) unless retrieval_consumed

      abstained_outcome(
        reason: :generation_failure,
        retrieval: retrieval,
        retrieval_ms: retrieval_ms,
        expansion_ms: expansion_ms,
        local_ms: local_before_generation_ms,
        generation_ms: generation_ms,
        expanded_chunks: expanded_chunks,
        chunks: chunks,
        expansions: expansions,
        prompt: prompt,
        raw_answer: raw_answer,
        model_invoked: prompt.present?
      )
    end

    private

    def expand_dividers(retrieved_chunks)
      expansions = []
      chunks = Array(retrieved_chunks).map do |chunk|
        next chunk unless expandable_divider?(chunk)

        expanded = expand(chunk)
        next chunk unless expanded

        expansions << {
          divider_chunk_sha256: chunk[:chunk_sha256],
          neighbor_chunk_sha256: expanded[:chunk][:chunk_sha256],
          mechanism: expanded[:mechanism],
          page_number: expanded[:chunk].dig(:metadata, "page_number")
        }
        inherit_source_identity(expanded[:chunk], chunk)
      end

      [ chunks.uniq { |chunk| chunk[:chunk_sha256] }, expansions ]
    end

    def expandable_divider?(chunk)
      metadata = chunk[:metadata].to_h.stringify_keys
      metadata["section_identity"].present? && divider_chunk?(chunk[:content])
    end

    def divider_chunk?(body)
      heading = body.to_s.lines.map(&:strip).find { |line| line.match?(HEADING_LINE) }
      heading.blank? && body.to_s.exclude?(SECTION_MARKER)
    end

    def expand(divider)
      page = Integer(divider.dig(:metadata, "page_number"), exception: false)
      return nil unless page&.positive?

      [ page + 1, page - 1 ].select(&:positive?).each do |target_page|
        result = @expander.neighbor_chunk(divider_chunk: divider, target_page: target_page)
        return result if result&.dig(:mechanism) == Rag::SectionNeighborExpander::MECHANISM_SECTION_IDENTITY
      end
      nil
    end

    def inherit_source_identity(neighbor, divider)
      neighbor.merge(
        original_source_uri: neighbor[:original_source_uri] || divider[:original_source_uri],
        bedrock_source_uri: neighbor[:bedrock_source_uri] || divider[:bedrock_source_uri]
      )
    end

    # The widened budget is for recall, not for widening the generation window.
    # Greedily cover the strongest identifier signal from the question, choosing
    # the chunk with the most identifier coverage and lexical agreement.
    def select_generation_chunks(chunks)
      analysis = Rag::QueryEntities.analyze(@question)
      labelled = analysis.identifiers.select { |identifier| identifier.position == :labelled }
      # Labelled identifiers are the strongest coverage signal and keep priority. When
      # the question has none — a paraphrase where the label and the identifier are not
      # adjacent — fall back to every extracted identifier rather than to blind rank
      # order, which would hand the generator the same top-3 the widened recall exists
      # to get past. Bare numerics never reach here (QueryEntities drops them).
      covering = labelled.presence || analysis.identifiers
      return Array(chunks).first(RagRetrievalProfile::PINNED_DOCUMENT_RESULTS) if covering.empty?

      uncovered = covering.map(&:canonical).to_set
      selected = []

      while uncovered.any? && selected.size < MAX_GENERATION_CHUNKS
        candidates = Array(chunks).reject { |chunk| selected.include?(chunk) }.filter_map do |chunk|
          covered = uncovered.select { |canonical| identifier_present?(chunk[:content], canonical) }
          next if covered.empty?

          [
            chunk,
            covered,
            analysis.identifiers.count { |identifier| identifier_present?(chunk[:content], identifier.canonical) },
            lexical_overlap(chunk[:content]),
            -(chunk[:rank] || Float::INFINITY)
          ]
        end
        break if candidates.empty?

        chunk, covered = candidates.max_by { |_item, hits, all_hits, overlap, rank| [ hits.size, all_hits, overlap, rank ] }
        selected << chunk
        uncovered.subtract(covered)
      end

      selected.presence || Array(chunks).first(RagRetrievalProfile::PINNED_DOCUMENT_RESULTS)
    end

    def identifier_present?(content, canonical)
      characters = canonical.to_s.scan(/[[:alnum:]]/)
      return false if characters.empty?

      pattern = characters.map { |character| Regexp.escape(character) }.join("[\\s\\-._]*")
      content.to_s.match?(/(?<![[:alnum:]_])#{pattern}(?![[:alnum:]_])/i)
    end

    def lexical_overlap(content)
      (lexical_tokens(@question) & lexical_tokens(content)).size
    end

    def lexical_tokens(text)
      I18n.transliterate(text.to_s).downcase.scan(/[[:alnum:]]+/).filter_map do |token|
        next if token.length < 4

        token.length > 5 ? token.sub(/[ao]\z/, "") : token
      end.to_set
    end

    def generation_prompt(chunks)
      template = BedrockRagService.load_generation_prompt_template
      rendered = template
        .sub("$query$") { @question }
        .sub("$search_results$") { evidence_context(chunks) }
        .sub(BedrockRagService::OUTPUT_FORMAT_PLACEHOLDER) do
          [ citation_instructions(chunks.size), verbatim_directive ].join("\n\n")
        end

      [ locale_directive, rendered ].compact_blank.join("\n\n")
    end

    def evidence_context(chunks)
      chunks.each_with_index.map do |chunk, index|
        metadata = chunk[:metadata].to_h.stringify_keys
        document = metadata["canonical_name"].presence ||
          File.basename(metadata["original_source_uri"].presence || chunk[:location_uri].to_s)
        page = metadata["page_number"].presence || "unknown"

        <<~EVIDENCE
          [EVIDENCE #{index + 1}]
          Document: #{document}
          Page: #{page}
          Chunk SHA256: #{chunk[:chunk_sha256]}
          Content:
          #{chunk[:content]}
        EVIDENCE
      end.join("\n")
    end

    def citation_instructions(chunk_count)
      <<~INSTRUCTIONS.strip
        Cite every supported technical claim with one or more evidence markers in
        the exact form [n], where n is between 1 and #{chunk_count}. A marker must
        refer only to the numbered evidence block that supports that claim. Do not
        emit a marker for unsupported or unavailable information.
      INSTRUCTIONS
    end

    # Documented labels are evidence, not prose to be improved. Measured 2026-07-30:
    # a route answer reproduced the identifier verbatim but rewrote the label string
    # it belongs to — expanding abbreviations, normalising punctuation and reordering
    # words — which destroys the traceability the citation is supposed to guarantee.
    def verbatim_directive
      <<~DIRECTIVE.strip
        When the answer to the question is a label, series name, table cell, field
        name, heading text or printed value taken from the evidence, reproduce that
        string exactly as printed — same characters, casing, abbreviations, internal
        punctuation and spacing — in quotes, before any explanation. Do not expand
        abbreviations, translate it, normalise punctuation, reorder its words or
        replace it with a description of its meaning. A paraphrase of a printed
        string is not an answer to a question about that string; add a plain-language
        gloss after the verbatim value if it helps, never instead of it.
      DIRECTIVE
    end

    def locale_directive
      language = { es: "Spanish", en: "English" }[locale]
      return nil unless language

      "Write the explanatory prose in #{language}, regardless of the evidence " \
        "language. Never translate or rewrite a value reproduced verbatim from the evidence."
    end

    def citation_shaped(chunks)
      chunks.map do |chunk|
        {
          content: chunk[:content],
          location: citation_location(chunk[:location_uri]),
          metadata: chunk[:metadata] || {}
        }
      end
    end

    def citation_location(uri)
      value = uri.to_s
      return nil if value.blank?

      bucket, key = value.delete_prefix("s3://").split("/", 2)
      { bucket: bucket, key: key, uri: value, type: "s3" }
    end

    def doc_refs(chunks)
      chunks.filter_map do |chunk|
        metadata = chunk[:metadata].to_h.stringify_keys
        source_uri = metadata["original_source_uri"].presence ||
          chunk[:original_source_uri].presence ||
          metadata["x-amz-bedrock-kb-source-uri"].presence ||
          chunk[:bedrock_source_uri].presence ||
          chunk[:location_uri].presence
        next if source_uri.blank?

        {
          "source_uri" => source_uri,
          "canonical_name" => metadata["canonical_name"].presence || File.basename(source_uri),
          "aliases" => Array(metadata["aliases"]).first(10),
          "doc_type" => metadata["doc_type"].presence || "unknown"
        }
      end.uniq { |ref| ref["source_uri"] }.presence
    end

    def structured_trace(retrieval:, retrieval_ms:, expansion_ms:, local_ms:, generation_ms:, chunks:, expansions:)
      retrieval[:retrieval_trace].to_h.deep_symbolize_keys.merge(
        structured_route: {
          retrieval_ms: retrieval_ms,
          expansion_ms: expansion_ms,
          local_ms: local_ms,
          generation_ms: generation_ms,
          retrieval_budget: RagRetrievalProfile::STRUCTURED_MAPPING_RESULTS,
          retrieved_chunks: Array(retrieval[:chunks]).size,
          generation_chunks: chunks.size,
          expansion_count: expansions.size,
          expansion_mechanisms: expansions.pluck(:mechanism).uniq
        }
      )
    end

    def valid_citations?(answer, citations, chunk_count)
      markers = answer.to_s.scan(/\[(\d+)\]/).flatten.map(&:to_i)
      return false if markers.empty?
      return false unless markers.all? { |number| number.between?(1, chunk_count) }

      citations.pluck(:number).sort == markers.uniq.sort
    end

    def abstained_outcome(reason:, retrieval:, retrieval_ms:, expansion_ms:, expanded_chunks:,
                          chunks:, expansions:, local_ms: 0, generation_ms: 0, prompt: nil,
                          raw_answer: nil, model_invoked: false)
      answer = Rag::AnswerSafetyProcessor.new(locale: locale).call(
        "DATA_NOT_AVAILABLE",
        evidence: []
      )
      trace = structured_trace(
        retrieval: retrieval,
        retrieval_ms: retrieval_ms,
        expansion_ms: expansion_ms,
        local_ms: local_ms,
        generation_ms: generation_ms,
        chunks: chunks,
        expansions: expansions
      )
      log_route(
        expansions: expansions,
        timings: trace[:structured_route],
        answer: answer,
        outcome: :abstained,
        reason: reason,
        prompt: prompt,
        raw_answer: raw_answer
      )

      result = {
        answer: answer,
        citations: [],
        retrieved_citations: [],
        doc_refs: doc_refs(chunks),
        retrieval_trace: trace,
        session_id: nil,
        generation_mode: GENERATION_MODE,
        model_invoked: model_invoked,
        retrieved_chunk_sha256s: chunks.pluck(:chunk_sha256),
        correlation_id: @correlation_id,
        diagnostics: {
          raw_answer: raw_answer,
          internal_answer: raw_answer,
          retrieved_chunks: expanded_chunks,
          generation_chunks: chunks,
          safety_evidence_chunks: citation_shaped(chunks),
          expansions: expansions,
          outcome_reason: reason
        }
      }
      Outcome.new(status: :abstained, result: result)
    end

    def log_route(expansions:, timings:, answer:, outcome:, prompt:, raw_answer:, reason: nil)
      Rag::EvidenceSelectionTelemetry.log_route(
        question: @question,
        answer: answer,
        generation_mode: GENERATION_MODE,
        account_id: @account_id,
        user_id: @user_id,
        conversation_session_id: @conversation_session_id,
        correlation_id: @correlation_id,
        retrieval_budget: RagRetrievalProfile::STRUCTURED_MAPPING_RESULTS,
        expansion_mechanisms: expansions.pluck(:mechanism),
        timings: timings,
        outcome: outcome,
        outcome_reason: reason,
        verbatim_directive: prompt.to_s.include?(verbatim_directive),
        generation_input_tokens: token_estimate(prompt),
        generation_output_tokens: token_estimate(raw_answer),
        generation_prompt_chars: prompt&.length
      )
    end

    def token_estimate(text)
      return nil if text.nil?

      AnthropicTokenCounter::LocalTokenizer.estimate(text.to_s)
    end

    def locale
      candidate = @response_locale.presence&.to_sym
      I18n.available_locales.include?(candidate) ? candidate : I18n.locale
    rescue StandardError
      :es
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((monotonic_now - started) * 1000).round
    end
  end
end
