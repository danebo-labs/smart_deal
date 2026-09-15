# frozen_string_literal: true

module Rag
  # Answers the technician's literal question, anchored to the field photo
  # just analyzed, through the same text RAG pipeline used for a normal chat
  # question (RagQueryConcern#execute_rag_query). Runs inside
  # FieldPhotoAnalysisJob, strictly after vision — never in the request cycle
  # (that route is fully async, see QueryOrchestratorService#execute).
  #
  # Two independent, deliberately narrow mechanisms (plan:
  # foto_mas_pregunta_correccion):
  #   - The anchor suffix steers RETRIEVAL, but only with tokens the KbDocument
  #     catalog actually recognizes (a display_name/alias hit via
  #     KbDocumentResolver.resolve_scoped). Raw OCR labels and invented part
  #     numbers never resolve to a document and used to scatter retrieval
  #     across the whole catalog instead of narrowing it — see "Diagnostico"
  #     in the plan. When nothing resolves, the literal question travels
  #     alone, same as any text-only turn.
  #   - The "Photo Evidence" session_context block is supporting CONTEXT for
  #     GENERATION, not a restriction: it tells the model what was read off
  #     the image so it can interpret the question, but procedures/values/
  #     part identity still come only from the retrieved manuals. The actual
  #     anti-substitution guardrail is the "# NO MATCH" instruction already in
  #     app/prompts/bedrock/generation.txt, which applies to every turn.
  #
  # entity_sources is deliberately left empty (conv_session is NOT passed to
  # execute_rag_query) so RagRetrievalProfile falls back to OPEN_RESULTS — the
  # photo itself is never pinned as an active_entity, so this is an open
  # catalog search, not a narrow pinned-document lookup. conversation_session_id
  # IS passed (see #call), purely for trace attribution — it does not affect
  # retrieval scoping.
  class PhotoQuestionAnswerService
    include RagQueryConcern

    ANCHOR_SUFFIX_MAX_CHARS = 120
    EVIDENCE_BLOCK_MAX_CHARS = 600
    UNKNOWN = "UNKNOWN"

    def initialize(question:, photo_value:, session:, account:, user_id:, correlation_id:, locale:)
      @question = question.to_s.strip
      @photo_value = photo_value.to_h.deep_symbolize_keys
      @session = session
      @account = account
      @user_id = user_id
      @correlation_id = correlation_id
      @locale = locale.to_s.presence&.to_sym
    end

    # @return [Hash, nil] { answer:, citations:, generation_mode: } or nil when
    #   the flag is off, the question is blank, or the RAG call did not succeed.
    def call
      return nil unless Rag::PhotoQuestionFlag.enabled?
      return nil if @question.blank?

      result = execute_rag_query(
        anchored_question,
        session_context: merged_session_context,
        entity_s3_uris:  SessionContextBuilder.entity_s3_uris(@session),
        account:         @account,
        user_id:         @user_id,
        response_locale: @locale,
        correlation_id:  @correlation_id,
        conversation_session_id: @session&.id
      )
      return nil unless result.success?

      processor        = Bedrock::CitationProcessor.new
      raw_citations    = processor.transport_references(result.citations)
      sources_visible  = Rag::SourcesVisibility.enabled?
      answer           = sources_visible ? result.answer : processor.strip_resolved_markers(result.answer, raw_citations)

      {
        answer: answer,
        citations: sources_visible ? raw_citations : [],
        generation_mode: result.generation_mode
      }
    end

    private

    # "Que equipo es y que está mostrando la pantalla ? (GECB System=1 Tools=2)"
    def anchored_question
      suffix = anchor_suffix
      suffix.present? ? "#{@question} (#{suffix})" : @question
    end

    # Only tokens the catalog knows (a display_name/alias hit) may steer
    # retrieval. Raw OCR labels and part numbers that resolve to nothing
    # ("000A60961010") scatter retrieval across the whole catalog instead.
    def anchor_suffix
      return "" unless @account

      candidate = [ known(@photo_value[:canonical_name]), known(@photo_value[:model_visible]), *visible_code_parts ].compact.join(" ")
      return "" if candidate.blank?

      question_down = @question.downcase
      tokens = KbDocumentResolver.resolve_scoped(candidate, account: @account)
                                 .flat_map(&:matched_tokens)
                                 .uniq { |token| token.downcase }
                                 .reject { |token| question_down.include?(token.downcase) }
      tokens.join(" ").truncate(ANCHOR_SUFFIX_MAX_CHARS, omission: "")
    end

    def visible_code_parts
      Array(@photo_value[:visible_codes]).map { |code| known(code) }.compact
    end

    def known(value)
      text = value.to_s.strip
      return nil if text.blank? || text.casecmp(UNKNOWN).zero?

      text
    end

    def merged_session_context
      base = SessionContextBuilder.build(@session)
      [ base.presence, photo_evidence_block ].compact.join("\n\n")
    end

    def photo_evidence_block
      visible_codes = Array(@photo_value[:visible_codes]).presence&.join(", ") || UNKNOWN
      block = <<~BLOCK.strip
        ## Photo Evidence (this turn)
        The technician attached a photo in this same turn and the question refers to it. The fields below were read from the image, not from the knowledge base; use them to interpret the question. Procedures, values and part identity come only from the retrieved manuals.
        - Component: #{@photo_value[:canonical_name] || UNKNOWN}
        - Manufacturer: #{@photo_value[:manufacturer] || UNKNOWN}
        - Model: #{@photo_value[:model_visible] || UNKNOWN}
        - Visible text/codes: #{visible_codes}
        - Condition: #{@photo_value[:condition] || UNKNOWN}
      BLOCK
      block.truncate(EVIDENCE_BLOCK_MAX_CHARS, omission: "")
    end
  end
end
