# frozen_string_literal: true

module Rag
  # Answers the technician's literal question, anchored to the field photo
  # just analyzed, through the same text RAG pipeline used for a normal chat
  # question (RagQueryConcern#execute_rag_query). Runs inside
  # FieldPhotoAnalysisJob, strictly after vision — never in the request cycle
  # (that route is fully async, see QueryOrchestratorService#execute).
  #
  # Two independent fixes are required (plan: foto_mas_pregunta_rag):
  #   - Anchored query text fixes RETRIEVAL. BedrockRagService#query only
  #     retrieves on the literal input.text, so a generic "qué es esto"
  #     would search the wrong equipment unless the visible component/codes
  #     ride along in the query string itself.
  #   - The "Photo Evidence" session_context block fixes GENERATION. Without
  #     it the model can still substitute a similar-looking component from a
  #     different manual instead of grounding on what was actually observed.
  #
  # entity_sources is deliberately left empty (conv_session is NOT passed to
  # execute_rag_query) so RagRetrievalProfile falls back to OPEN_RESULTS — the
  # photo itself is never pinned as an active_entity, so this is an open
  # catalog search, not a narrow pinned-document lookup.
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
        correlation_id:  @correlation_id
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

    def anchor_suffix
      parts = [ known(@photo_value[:canonical_name]), *visible_code_parts ].compact
      return "" if parts.empty?

      parts.join(" ").truncate(ANCHOR_SUFFIX_MAX_CHARS, omission: "")
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
        The technician attached a photo in this same turn and the question refers to it. The fields below are the ONLY visual evidence and were read from the image, not from the knowledge base. Never infer a value that is not listed here or retrieved from the manuals. If the manuals contain no evidence for this question, state that explicitly instead of substituting a similar component from another manual.
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
