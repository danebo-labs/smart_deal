# frozen_string_literal: true

module Rag
  # Resolves generic LED/lock/safety-contact questions without asking a blind
  # clarification. A single Retrieve call inspects the available evidence. When
  # it spans several documented manufacturer/model pairs, the responder shows
  # three concrete choices and lets the technician narrow the next query.
  class AmbiguousModelResponder
    MIN_DISTINCT_MODELS = 3
    # Matches ContractualLimits::QUERY[:max_top_k]. Same single Retrieve, no
    # extra call and no generation cost — 8 was leaving documented boards
    # (EM4000, p. 33) out of the candidate pool entirely.
    RETRIEVAL_RESULTS = 20
    MAX_OPTIONS = 3

    MODEL_PATTERN =
      /\b(?:[A-Z]{2,}\d+[A-Z0-9.-]*|[A-Z]{2,}(?:-[A-Z0-9]+)+)\b/.freeze

    def self.build(question:, account:, entity_s3_uris:, entity_sources:, force_entity_filter:,
                   response_locale: nil, output_channel: nil, user_id: nil,
                   conversation_session_id: nil, correlation_id: nil)
      return unless DeterministicIntent.ambiguous_hardware_query?(question)

      new(
        question: question,
        account: account,
        entity_s3_uris: entity_s3_uris,
        entity_sources: entity_sources,
        force_entity_filter: force_entity_filter,
        response_locale: response_locale,
        output_channel: output_channel,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id
      )
    end

    def initialize(question:, account:, entity_s3_uris:, entity_sources:, force_entity_filter:,
                   response_locale: nil, output_channel: nil, rag_service: nil, user_id: nil,
                   conversation_session_id: nil, correlation_id: nil, generator: nil)
      @question = question
      @account = account
      @service = rag_service || BedrockRagService.new(account: account)
      @entity_s3_uris = Array(entity_s3_uris)
      @entity_sources = Array(entity_sources)
      @force_entity_filter = force_entity_filter
      @locale = response_locale.presence&.to_sym || I18n.locale
      @output_channel = output_channel&.to_sym
      @user_id = user_id
      @conversation_session_id = conversation_session_id
      @correlation_id = correlation_id
      @generator = generator
    end

    def execute
      retrieval_started = monotonic_now
      retrieval = @service.retrieve_chunks(
        @question,
        entity_s3_uris: @entity_s3_uris,
        entity_sources: @entity_sources,
        force_entity_filter: @force_entity_filter,
        number_of_results: RETRIEVAL_RESULTS,
        account_id: @account&.id
      )
      retrieval_ms = elapsed_ms(retrieval_started)
      candidates = candidates_from(retrieval[:chunks])
      # DeterministicIntent#ambiguous_hardware_query? is purely lexical over the
      # raw question, so a board whose name carries no digit at all ("Twister TW
      # de Embarba", measured 2026-07-31) lands here even though the technician
      # named it unambiguously. The retrieved headings are the KB's own answer to
      # "which boards are on the table", so ask them instead of widening
      # EXPLICIT_EQUIPMENT_PATTERN's fixed manufacturer list, which only defers
      # the problem to the next board without a digit.
      named = candidates.select { |candidate| Rag::BoardHeading.mentioned?(candidate[:label], @question) }
      # Exactly one named board: there is no ambiguity left to resolve and the
      # menu would ask the technician to repeat what they already wrote. Answer
      # from the retrieval in hand — returning nil to fall through would bill a
      # second Retrieve for the same turn.
      return answer_from(retrieval, retrieval_ms: retrieval_ms) if answer_directly?(named)

      return if candidates.size < MIN_DISTINCT_MODELS

      # Two or more named: still ambiguous, but the technician already narrowed
      # the set, so the menu offers only what they named.
      selected = (named.many? ? named : candidates).first(MAX_OPTIONS)
      used_chunks = selected.pluck(:chunk)
      {
        answer: render_answer(selected),
        citations: numbered_references(used_chunks),
        retrieved_citations: citation_shaped(used_chunks),
        doc_refs: doc_refs(used_chunks),
        retrieval_trace: retrieval[:retrieval_trace],
        session_id: nil,
        generation_mode: "deterministic_model_disambiguation",
        model_invoked: false,
        quick_replies: selected.map do |candidate|
          {
            label: candidate[:label],
            query: "#{@question}\n#{I18n.t('rag.model_selection_query', locale: @locale, model: candidate[:label])}"
          }
        end
      }
    rescue BedrockRagService::BedrockServiceError => e
      Rails.logger.warn("Rag::AmbiguousModelResponder: retrieval failed — #{e.message}")
      nil
    end

    private

    # Gated on the live-route switch: with it off, this responder keeps showing
    # the menu exactly as it does today, so the rollback lever still means one
    # thing and there is no third combination of states to reason about.
    def answer_directly?(named)
      Rag::StructuredEvidenceRouteFlag.enabled? && named.one?
    end

    # Hands the already-consumed retrieval to the structured route so the answer
    # goes through the same generation and safety stack as every other evidence
    # answer. Built with `new`, not `build`: the question is precisely one that
    # RagRetrievalProfile#structured_mapping_query? rejects (no digit in the
    # designator), which is why it reached this responder at all.
    def answer_from(retrieval, retrieval_ms:)
      Rag::StructuredEvidenceRoute.new(
        question: @question,
        account: @account,
        entity_s3_uris: @entity_s3_uris,
        entity_sources: @entity_sources,
        force_entity_filter: @force_entity_filter,
        response_locale: @locale,
        account_id: @account&.id,
        user_id: @user_id,
        conversation_session_id: @conversation_session_id,
        correlation_id: @correlation_id,
        rag_service: @service,
        generator: @generator
      ).complete_from_retrieval(retrieval, retrieval_ms: retrieval_ms).result
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((monotonic_now - started) * 1000).round
    end

    def candidates_from(chunks)
      seen = {}
      Array(chunks).filter_map do |chunk|
        metadata = chunk[:metadata].to_h.stringify_keys
        searchable = [
          metadata["manufacturer"],
          metadata["controller_model"],
          metadata["board_model"],
          metadata["canonical_name"],
          Array(metadata["aliases"]).join(" "),
          chunk[:content].to_s.first(2_000)
        ].compact.join(" ")

        # The section heading IS the board ("EM3000 - HIDRAULICO", "NE 300 – LB II").
        # It comes straight from the page, so it can never name a board that is
        # not there — unlike the metadata fallback below.
        label = Rag::BoardHeading.label(chunk[:content]).presence || metadata_label(metadata, searchable)
        next if label.blank?

        key = label.downcase
        next if seen[key]

        seen[key] = true
        { label: label, chunk: chunk }
      end
    end

    # Only concatenates when the chunk carries an explicit manufacturer in
    # metadata. Scanning the chunk body instead made every page of a multi-brand
    # manual look like ALTIUS, offering boards that are not on that page.
    def metadata_label(metadata, searchable)
      manufacturer = metadata["manufacturer"].presence
      return if manufacturer.blank?

      model = metadata["controller_model"].presence ||
        metadata["board_model"].presence ||
        searchable.scan(MODEL_PATTERN).first
      return if model.blank?

      "#{manufacturer} — #{model}"
    end

    def render_answer(candidates)
      prompt = I18n.t("rag.ambiguous_model_prompt", locale: @locale)
      # Web renders the same options as tappable chips (quick_replies); printing
      # them again as a numbered list is pure visual duplication.
      return prompt if @output_channel == :web

      options = candidates.each_with_index.map { |candidate, index| "#{index + 1}. #{candidate[:label]}" }
      [ prompt, options.join("\n") ].join("\n\n")
    end

    def citation_shaped(chunks)
      chunks.map do |chunk|
        {
          content: chunk[:content],
          location: { uri: chunk[:location_uri] },
          metadata: chunk[:metadata] || {}
        }
      end
    end

    def numbered_references(chunks)
      citations = citation_shaped(chunks)
      markers = citations.each_index.map { |index| "[#{index + 1}]" }.join(" ")
      Bedrock::CitationProcessor.new.build_numbered_references(citations, markers, question: @question)
    end

    def doc_refs(chunks)
      chunks.filter_map do |chunk|
        uri = chunk[:original_source_uri] || chunk[:bedrock_source_uri] || chunk[:location_uri]
        next if uri.blank?

        metadata = chunk[:metadata].to_h.stringify_keys
        {
          "source_uri" => uri,
          "canonical_name" => metadata["canonical_name"].presence || File.basename(uri),
          "aliases" => [],
          "doc_type" => "schematic"
        }
      end.uniq { |ref| ref["source_uri"] }
    end
  end
end
