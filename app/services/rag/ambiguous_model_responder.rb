# frozen_string_literal: true

module Rag
  # Resolves generic LED/lock/safety-contact questions without asking a blind
  # clarification. A single Retrieve call inspects the available evidence. When
  # it spans several documented manufacturer/model pairs, the responder asks
  # one question in prose that names up to three boards (CG-D19: no chips), so
  # the technician can narrow the next query in their own words.
  class AmbiguousModelResponder
    MIN_DISTINCT_MODELS = 3
    # Matches ContractualLimits::QUERY[:max_top_k]. Same single Retrieve, no
    # extra call and no generation cost — 8 was leaving documented boards
    # (EM4000, p. 33) out of the candidate pool entirely.
    RETRIEVAL_RESULTS = 20
    MAX_OPTIONS = 3

    def self.build(question:, account:, entity_s3_uris:, entity_sources:, force_entity_filter:,
                   response_locale: nil, user_id: nil,
                   conversation_session_id: nil, correlation_id: nil,
                   raw_question: nil, session_context: nil, episode: nil, equipment_identity: :omit)
      return unless DeterministicIntent.ambiguous_hardware_query?(question)

      new(
        question: question,
        account: account,
        entity_s3_uris: entity_s3_uris,
        entity_sources: entity_sources,
        force_entity_filter: force_entity_filter,
        response_locale: response_locale,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        raw_question: raw_question,
        session_context: session_context,
        episode: episode,
        equipment_identity: equipment_identity
      )
    end

    def initialize(question:, account:, entity_s3_uris:, entity_sources:, force_entity_filter:,
                   response_locale: nil, rag_service: nil, user_id: nil,
                   conversation_session_id: nil, correlation_id: nil, generator: nil,
                   raw_question: nil, session_context: nil, episode: nil, equipment_identity: :omit)
      @question = question
      @account = account
      @service = rag_service || BedrockRagService.new(account: account)
      @entity_s3_uris = Array(entity_s3_uris)
      @entity_sources = Array(entity_sources)
      @force_entity_filter = force_entity_filter
      @locale = response_locale.presence&.to_sym || I18n.locale
      @user_id = user_id
      @conversation_session_id = conversation_session_id
      @correlation_id = correlation_id
      @generator = generator
      @raw_question = raw_question
      @session_context = session_context
      @episode = episode
      @equipment_identity = equipment_identity
    end

    def execute
      retrieval_started = monotonic_now
      retrieval = @service.retrieve_chunks(
        @question,
        entity_s3_uris: @entity_s3_uris,
        entity_sources: @entity_sources,
        force_entity_filter: @force_entity_filter,
        number_of_results: RETRIEVAL_RESULTS,
        account_id: @account&.id,
        user_id: @user_id,
        conversation_session_id: @conversation_session_id,
        correlation_id: @correlation_id,
        route_taken: "model_disambiguation"
      )
      retrieval_ms = elapsed_ms(retrieval_started)
      return denied_result(retrieval) if denied_retrieval?(retrieval)

      chunks = retrieval[:chunks]
      candidates = candidates_from(chunks)
      # DeterministicIntent#ambiguous_hardware_query? is purely lexical over the
      # raw question, so a board whose name carries no digit at all lands here
      # even when the technician named it. Only an explicit board slot is a plate.
      named = candidates.select { |candidate| Rag::BoardHeading.mentioned?(candidate[:label], @question) }
      # Exactly one named board: there is no ambiguity left to resolve and the
      # menu would ask the technician to repeat what they already wrote.
      return answer_from(retrieval, retrieval_ms: retrieval_ms) if answer_directly?(named)
      return menu(candidates, named, retrieval) if clarify?(chunks, candidates, named)

      # The Retrieve already happened. Finish on that result: generate, or
      # abstain inside the route when the evidence or the generation is empty.
      # Nil would send the orchestrator through another search.
      answer_from(retrieval, retrieval_ms: retrieval_ms)
    rescue BedrockRagService::BedrockServiceError => e
      Rails.logger.warn("Rag::AmbiguousModelResponder: retrieval failed — #{e.message}")
      nil
    end

    private

    # Gated on the live-route switch: with it off, one named board still gets
    # the menu this responder already showed. A section heading is not that
    # case: it never becomes a plate, with the flag on or off.
    def answer_directly?(named)
      Rag::StructuredEvidenceRouteFlag.enabled? && named.one?
    end

    # MIN_DISTINCT_MODELS is the existing menu threshold for a generic hardware
    # question that retrieved that many explicit board slots. The count is not
    # proof that the slots are different machines beyond the metadata that
    # named them. Below that threshold, two slots clarify only when
    # FamilyAmbiguityDetector finds the asked identifier on more than one of
    # them and the question names neither. Two labels without that collision
    # are not a clarification. A location question on the selected document
    # uses the same collision, including when three or more slots were retrieved.
    def clarify?(chunks, candidates, named)
      collision = plate_identifier_collision?(chunks, named)
      return true if collision && candidates.size < MIN_DISTINCT_MODELS
      return false if candidates.size < MIN_DISTINCT_MODELS
      return true if named.many?
      return true unless selected_document_location?

      collision
    end

    def plate_identifier_collision?(chunks, named)
      return false if named.any?

      Rag::FamilyAmbiguityDetector.new.call(
        question_analysis: Rag::QueryEntities.analyze(@raw_question.presence || @question),
        chunks: chunks
      ).ambiguous?
    end

    def denied_retrieval?(retrieval)
      retrieval.to_h[:retrieval].to_s == BedrockRagService::DENY_RETRIEVAL
    end

    # The pin check can also fail inside retrieve_chunks. That hash is terminal:
    # do not generate from it and do not return nil, which would open another search.
    def denied_result(retrieval)
      BedrockRagService.deny_retrieval_result(
        question: @question,
        response_locale: @locale
      ).merge(retrieval_trace: retrieval[:retrieval_trace])
    end

    def selected_document_location?
      return false if @entity_s3_uris.blank?

      text = @raw_question.presence || @question
      Rag::QueryEntities.requested_relation(text).include?(:location)
    end

    def menu(candidates, named, retrieval)
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
        pending_question: { "type" => "choice", "options" => selected.pluck(:label) }
      }
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
        generator: @generator,
        raw_question: @raw_question,
        session_context: @session_context,
        episode: @episode,
        equipment_identity: @equipment_identity
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
        # Only the board slot. A heading, a section, a controller, a
        # manufacturer, and a code in the body are not plates.
        label = Rag::PlateIdentity.designator(chunk)
        next if label.blank?

        key = label.downcase
        next if seen[key]

        seen[key] = true
        { label: label, chunk: chunk }
      end
    end

    # One question in prose. The names are explicit board slots, so the
    # sentence does not name a plate the metadata did not.
    def render_answer(candidates)
      connector = I18n.t("rag.ambiguous_model_connector", locale: @locale)
      models = candidates.pluck(:label).to_sentence(
        words_connector: ", ", two_words_connector: connector, last_word_connector: connector
      )
      I18n.t("rag.ambiguous_model_question", locale: @locale, models: models)
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
