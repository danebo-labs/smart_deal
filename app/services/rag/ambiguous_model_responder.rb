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

    MODEL_PATTERN =
      /\b(?:[A-Z]{2,}\d+[A-Z0-9.-]*|[A-Z]{2,}(?:-[A-Z0-9]+)+)\b/.freeze

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
      chunks = retrieval[:chunks]
      candidates = candidates_from(chunks)
      # DeterministicIntent#ambiguous_hardware_query? is purely lexical over the
      # raw question, so a board whose name carries no digit at all ("Twister TW
      # de Embarba", measured 2026-07-31) lands here even though the technician
      # named it unambiguously. An opening board declaration or an explicit
      # plate slot is the KB's own answer to "which boards are on the table".
      # A later section heading is not. Widening EXPLICIT_EQUIPMENT_PATTERN's
      # manufacturer list only defers the problem to the next board without a digit.
      named = candidates.select { |candidate| Rag::BoardHeading.mentioned?(candidate[:label], @question) }
      # Exactly one named board: there is no ambiguity left to resolve and the
      # menu would ask the technician to repeat what they already wrote. Answer
      # from the retrieval in hand — returning nil to fall through would bill a
      # second Retrieve for the same turn.
      return answer_from(retrieval, retrieval_ms: retrieval_ms) if answer_directly?(named)
      return menu(candidates, named, retrieval) if clarify?(chunks, candidates, named)

      # Evidence is already in hand. A section heading did not prove a plate,
      # and fewer than three explicit plates do not prove that none exist.
      # Nil here would send the orchestrator through another Retrieve.
      return answer_from(retrieval, retrieval_ms: retrieval_ms) if reuse_retrieval?(chunks, candidates)

      nil
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

    # Three explicit plates, and the answer depends on which one. A question
    # about the selected document's location depends on a plate only when the
    # same identifier is documented on more than one of those plates.
    def clarify?(chunks, candidates, named)
      return false if candidates.size < MIN_DISTINCT_MODELS
      return true if named.many?
      return true unless selected_document_location?

      Rag::FamilyAmbiguityDetector.new.call(
        question_analysis: Rag::QueryEntities.analyze(@question),
        chunks: chunks
      ).ambiguous?
    end

    # Empty plate set: the headings were sections, or no plate was declared.
    # A location question on the selected document reuses the retrieval even
    # when a plate slot is present but the answer does not depend on it.
    # One or two explicit plates on any other question stay on the previous
    # fallthrough: this responder does not own that turn.
    def reuse_retrieval?(chunks, candidates)
      return false if Array(chunks).empty?

      candidates.empty? || selected_document_location?
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
        metadata = chunk[:metadata].to_h.stringify_keys
        searchable = [
          metadata["manufacturer"],
          metadata["controller_model"],
          metadata["board_model"],
          metadata["canonical_name"],
          Array(metadata["aliases"]).join(" "),
          chunk[:content].to_s.first(2_000)
        ].compact.join(" ")

        # An opening "## " declaration or an explicit plate slot can name a
        # board. A later "## " only extracts a section. Manufacturer stays in
        # metadata_label and is not treated as the plate slot.
        label = Rag::PlateIdentity.designator(chunk).presence ||
          Rag::PlateIdentity.declared_board_heading(chunk[:content]).presence ||
          metadata_label(metadata, searchable)
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

    # One question in prose. The board names come from the retrieved headings
    # or metadata, so the sentence never names a board that is not on the table.
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
