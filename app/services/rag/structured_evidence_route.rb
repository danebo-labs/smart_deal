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
      @ambiguity = nil
    end

    def execute
      retrieval_started = monotonic_now
      retrieval =
        begin
          @rag_service.retrieve_chunks(
            @question,
            entity_s3_uris: @entity_s3_uris,
            entity_sources: @entity_sources,
            force_entity_filter: @force_entity_filter,
            number_of_results: RagRetrievalProfile::STRUCTURED_MAPPING_RESULTS,
            account_id: @account_id,
            correlation_id: @correlation_id
          )
        rescue BedrockRagService::BedrockServiceError => e
          Rails.logger.warn("Rag::StructuredEvidenceRoute: AWS path failed — #{e.message}")
          return Outcome.new(status: :unavailable, result: nil)
        rescue StandardError => e
          Rails.logger.warn("Rag::StructuredEvidenceRoute: failed — #{e.class}: #{e.message}")
          return Outcome.new(status: :unavailable, result: nil)
        end

      complete_from_retrieval(retrieval, retrieval_ms: elapsed_ms(retrieval_started))
    end

    # Everything after the Retrieve, so a caller that already spent the turn's
    # single Retrieve can finish on that evidence instead of billing a second
    # one. Rag::AmbiguousModelResponder is that caller: it can only tell that the
    # question already names one board after looking at the retrieved chunks.
    # Kept as one method rather than copied into the responder because the eight
    # steps below — chunk selection, prompt, generation, marker normalization,
    # absence semantics, answer safety, attribution guard, citation validation —
    # are the safety stack, and two copies of it would drift.
    #
    # Never returns :unavailable: the Retrieve is already consumed by definition,
    # so every failure below abstains rather than letting a cascade re-retrieve.
    def complete_from_retrieval(retrieval, retrieval_ms: 0)
      expansion_ms = 0
      local_before_generation_ms = 0
      generation_ms = 0
      expanded_chunks = []
      expansions = []
      chunks = []
      prompt = nil
      raw_answer = nil
      attribution = nil

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
          expansions: expansions,
          attribution: attribution
        )
      end

      local_started = monotonic_now
      @ambiguity = detect_family_ambiguity(expanded_chunks)
      chunks = select_generation_chunks(expanded_chunks, ambiguity: @ambiguity)
      citation_evidence = citation_shaped(chunks)
      prompt = generation_prompt(chunks, ambiguity: @ambiguity)
      local_before_generation_ms = elapsed_ms(local_started)

      generation_started = monotonic_now
      raw_answer = @generator.query(
        prompt,
        max_tokens: BedrockRagService::DEFAULT_RAG_CONFIG[:generation_max_tokens],
        temperature: BedrockRagService::DEFAULT_RAG_CONFIG[:generation_temperature],
        tracking: {
          account_id: @account_id,
          user_id: @user_id,
          conversation_session_id: @conversation_session_id,
          correlation_id: @correlation_id
        }
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
          model_invoked: true,
          attribution: attribution
        )
      end

      local_after_generation_started = monotonic_now
      generated_answer = Rag::CitationMarkerNormalizer.call(
        raw_answer,
        evidence_count: chunks.size,
        evidence_text: chunks.pluck(:content).join("\n")
      )
      internal_answer = BedrockRagService.allocate.send(
        :normalize_absence_semantics,
        generated_answer,
        question: @question,
        locale: locale
      )
      answer = Rag::AnswerSafetyProcessor.new(locale: locale).call(
        internal_answer,
        evidence: citation_evidence,
        require_cited_evidence: true
      )
      attribution = Rag::CitationAttributionGuard.new(
        question: @question, citations: citation_evidence
      ).call(answer)
      answer = attribution.answer
      citations = @citation_processor.build_numbered_references(
        citation_evidence,
        answer,
        question: @question
      )
      local_ms = local_before_generation_ms + elapsed_ms(local_after_generation_started)
      unless valid_citations?(answer, citations, chunks.size)
        return abstained_outcome(
          reason: attribution.dropped_any? ? :attribution_failure : :citation_failure,
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
          model_invoked: true,
          attribution: attribution
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
        raw_answer: raw_answer,
        attribution_dropped: attribution.dropped_segments.size,
        chunks: chunks,
        citations: citations,
        attribution: attribution
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
        # Structural ground truth (empty evidence / generation failure / bad
        # citations all short-circuit into abstained_outcome before this point) —
        # RagController must prefer this over regexing the rendered answer, since
        # a fully-answered response can legitimately contain an inline "El
        # documento no incluye este dato" caveat about one sub-detail.
        route_outcome: :answered,
        retrieved_chunk_sha256s: chunks.pluck(:chunk_sha256),
        correlation_id: @correlation_id,
        diagnostics: {
          raw_answer: raw_answer,
          normalized_answer: generated_answer,
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
        model_invoked: prompt.present?,
        attribution: attribution
      )
    rescue StandardError => e
      Rails.logger.warn("Rag::StructuredEvidenceRoute: failed — #{e.class}: #{e.message}")
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
        model_invoked: prompt.present?,
        attribution: attribution
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

    # Evidence-level ambiguity is checked before the cover greedy narrows the
    # window: the retrieval that answered "¿A qué serie corresponde el LED SPM?"
    # carried both Sistel boards, and the cover reduced them to one chunk. Local
    # work only — no extra Retrieve, no extra generation.
    def detect_family_ambiguity(chunks)
      return nil unless Rag::FamilyAmbiguityGuardFlag.enabled?

      Rag::FamilyAmbiguityDetector.new.call(
        question_analysis: question_analysis,
        chunks: chunks
      )
    end

    def question_analysis
      @question_analysis ||= Rag::QueryEntities.analyze(@question)
    end

    # The widened budget is for recall, not for widening the generation window.
    # Greedily cover the strongest identifier signal from the question, choosing
    # the chunk with the most identifier coverage and lexical agreement.
    def select_generation_chunks(chunks, ambiguity: nil)
      return board_coverage_chunks(ambiguity) if ambiguity&.ambiguous?

      analysis = question_analysis
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

      return Array(chunks).first(RagRetrievalProfile::PINNED_DOCUMENT_RESULTS) if selected.empty?

      add_named_board_coverage(selected, chunks, covering)
    end

    # Comparative questions ("ARCA básica vs ARCA III") name two boards that both
    # document the identifier being asked about; the cover greedy above stops as
    # soon as one chunk covers every identifier, which can leave the second named
    # board unrepresented even though the question explicitly asked about it.
    # Sibling of the ambiguity guard, not a duplicate: 0 named boards is the
    # ambiguity guard's job (above), ≥2 named boards is this pass's job — a board
    # the technician already named is never something to ask them about. Gated on
    # the same rollback switch as that guard: off means selection is byte-identical
    # to before this pass existed, which the archived D5 replay fidelity depends on.
    def add_named_board_coverage(selected, chunks, covering)
      return selected unless Rag::FamilyAmbiguityGuardFlag.enabled?

      boards = named_boards(chunks)
      return selected if boards.size < 2

      represented = selected.filter_map { |chunk| board_key(chunk) }.to_set
      canonicals = covering.map(&:canonical)

      boards.each do |board|
        break if selected.size >= MAX_GENERATION_CHUNKS
        next if represented.include?(board[:key])

        addition = board[:chunks]
          .reject { |chunk| selected.include?(chunk) }
          .select { |chunk| canonicals.any? { |canonical| identifier_present?(chunk[:content], canonical) } }
          .max_by { |chunk| selection_score(chunk) }
        next unless addition

        selected << addition
        represented << board[:key]
      end

      selected
    end

    # Groups chunks by board identity (same key as Rag::FamilyAmbiguityDetector:
    # the "## " heading label, falling back to metadata section_identity), keeping
    # only the boards the question actually names. A board can be named through
    # any of its candidate strings — its own heading, the "**Section:**" line a
    # generic table heading hides it behind, or the document's section_identity —
    # so a real board is never missed for lack of a distinctive "## " line. The
    # specificity rule then drops a named board whose matched tokens are a strict
    # subset of another named board's — "ARCA" alone must not ride along on a
    # question that already specified "ARCA básica".
    def named_boards(chunks)
      boards = Array(chunks).group_by { |chunk| board_key(chunk) }.filter_map do |key, board_chunks|
        next if key.nil?

        tokens = board_chunks.flat_map { |chunk| matched_board_tokens(chunk) }.to_set
        next if tokens.empty?

        { key: key, chunks: board_chunks, tokens: tokens }
      end

      boards.reject do |board|
        boards.any? { |other| other[:key] != board[:key] && board[:tokens].proper_subset?(other[:tokens]) }
      end
    end

    def board_key(chunk)
      heading = Rag::BoardHeading.label(chunk[:content]).presence
      heading = nil if heading && Rag::BoardHeading.board_tokens(heading).empty?

      heading || chunk[:metadata].to_h.stringify_keys["section_identity"].presence
    end

    def matched_board_tokens(chunk)
      metadata = chunk[:metadata].to_h.stringify_keys
      candidates = [
        Rag::BoardHeading.label(chunk[:content]),
        Rag::BoardHeading.section_label(chunk[:content]),
        metadata["section_identity"]
      ].compact_blank.uniq

      candidates
        .select { |candidate| Rag::BoardHeading.mentioned?(candidate, @question) }
        .flat_map { |candidate| Rag::BoardHeading.board_tokens(candidate) }
    end

    # One chunk per board family that documents the ambiguous identifier, ranked
    # by the same criteria as the cover greedy (identifier coverage, lexical
    # agreement, retrieval rank). The generator must see every documented meaning
    # to enumerate them; picking the strongest board would be exactly the
    # confident single-family answer this guard exists to prevent.
    def board_coverage_chunks(ambiguity)
      ambiguity.chunks_by_board.values
        .filter_map { |board_chunks| board_chunks.max_by { |chunk| selection_score(chunk) } }
        .sort_by { |chunk| selection_score(chunk) }
        .reverse
        .first(MAX_GENERATION_CHUNKS)
        .sort_by { |chunk| chunk[:rank] || Float::INFINITY }
    end

    def selection_score(chunk)
      [
        question_analysis.identifiers.count { |identifier| identifier_present?(chunk[:content], identifier.canonical) },
        lexical_overlap(chunk[:content]),
        -(chunk[:rank] || Float::INFINITY)
      ]
    end

    def identifier_present?(content, canonical)
      Rag::QueryEntities.identifier_present?(content, canonical)
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

    def generation_prompt(chunks, ambiguity: nil)
      template = BedrockRagService.load_generation_prompt_template
      rendered = template
        .sub("$query$") { @question }
        .sub("$search_results$") { evidence_context(chunks) }
        .sub(BedrockRagService::OUTPUT_FORMAT_PLACEHOLDER) do
          [
            citation_instructions(chunks.size),
            verbatim_directive,
            (multi_family_directive if ambiguity&.ambiguous?)
          ].compact.join("\n\n")
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

    # Emitted only when Rag::FamilyAmbiguityDetector found one identifier
    # documented on several boards and no board named in the question. Choosing a
    # family here is a safety incident, not a helpful default: SPM is a different
    # series on each Sistel board, so the answer has to enumerate and ask.
    def multi_family_directive
      <<~DIRECTIVE.strip
        The evidence spans multiple distinct board families for the identifier
        asked about. Enumerate the meaning per board family, citing each with its
        own marker; state explicitly that the answer depends on which board the
        technician has, and ask which board it is. Never pick one family on the
        technician's behalf.
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
                          raw_answer: nil, model_invoked: false, attribution: nil)
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
        raw_answer: raw_answer,
        chunks: chunks,
        attribution: attribution
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
        route_outcome: :abstained,
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

    def log_route(expansions:, timings:, answer:, outcome:, prompt:, raw_answer:, reason: nil,
                  attribution_dropped: 0, chunks: [], citations: [], attribution: nil)
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
        expansions: expansions,
        timings: timings,
        outcome: outcome,
        outcome_reason: reason,
        verbatim_directive: prompt.to_s.include?(verbatim_directive),
        generation_input_tokens: token_estimate(prompt),
        generation_output_tokens: token_estimate(raw_answer),
        generation_prompt_chars: prompt&.length,
        attribution_dropped: attribution_dropped,
        ambiguity_detected: @ambiguity&.ambiguous?,
        ambiguity_identifier: @ambiguity&.identifier,
        ambiguity_families: @ambiguity&.board_keys,
        chunks: chunks,
        attribution: attribution,
        model: BedrockClient::DEFAULT_MODEL_ID
      )
      # Same [PILOT_AUDIT] contract as the classic RAG path (BedrockRagService#
      # log_quality_signal) — the pitch/audit dossier must not go blank just
      # because the answer came from this route instead of that one.
      PilotAuditLog.log(
        question: @question,
        answer: answer,
        citations: citations,
        retrieved_chunks: chunks,
        correlation_id: @correlation_id,
        attribution: { account_id: @account_id, user_id: @user_id, conversation_session_id: @conversation_session_id }
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
