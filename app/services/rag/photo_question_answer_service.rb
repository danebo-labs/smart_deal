# frozen_string_literal: true

module Rag
  # Answers the technician's literal question, anchored to the field photo
  # just analyzed, through the same text RAG pipeline used for a normal chat
  # question (RagQueryConcern#execute_rag_query). Runs inside
  # FieldPhotoAnalysisJob, strictly after vision — never in the request cycle
  # (that route is fully async, see QueryOrchestratorService#execute).
  #
  # Two independent, deliberately narrow mechanisms (plan:
  # foto_mas_pregunta_correccion, gates v2: ancla_foto_v2_quirurgico):
  #   - The anchor suffix steers RETRIEVAL, but only with tokens that clear
  #     TWO deterministic gates: (1) catalog — a display_name/alias hit via
  #     KbDocumentResolver.resolve_scoped; invented part numbers
  #     ("000A60961010") never resolve; (2) form —
  #     KbDocumentResolver.specific_token? (digits, or fully uppercase and
  #     not a bare brand). Gate 1 alone let generic words that merely live
  #     inside some alias ("portátil", "Motor", "System") mis-scope
  #     retrieval — regresion 2026-09-15. When nothing clears both gates, the
  #     literal question travels alone, same as any text-only turn.
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
    EVIDENCE_BLOCK_MAX_CHARS = 720
    UNKNOWN = "UNKNOWN"
    # H9: laptop-screen capture of a sheet. Accent-folded titles; plant pattern
    # is 4+ uppercase letters + digits. No site name is hardcoded (D10).
    DOCUMENT_ON_SCREEN_TITLES = [
      "caracteristicas motor",
      "fijacion de cables"
    ].freeze
    PLANT_IDENTIFIER_PATTERN = /\b[A-Z]{4,}\s+\d{2,}\b/

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

    # Retrieval anchor. Two deterministic gates, both required:
    #   1. catalog: the token must match a display_name/alias (resolve_scoped) —
    #      invented part numbers ("000A60961010") never resolve;
    #   2. form: KbDocumentResolver.specific_token? (digits or fully uppercase
    #      non-brand). Generic words living in some alias ("portátil" from
    #      "Terminal portátil OTIS", "Motor", "System") passed gate 1 alone and
    #      mis-scoped retrieval — regresion 2026-09-15.
    # visible_codes is verbatim screen/label text: it only contributes
    # digit-bearing designators (708A, MX10). Uppercase UI words (MODULE,
    # FUNCTION, SET) pass specific_token? but name no document.
    def anchor_suffix
      return "" unless @account

      identity = [ known(@photo_value[:canonical_name]), known(@photo_value[:model_visible]) ].compact.join(" ")
      identity_tokens = raw_tokens(identity).select { |raw| KbDocumentResolver.specific_token?(raw) }
      code_tokens     = raw_tokens(visible_code_parts.join(" ")).select { |raw| raw.match?(/\d/) }
      candidate = (identity_tokens + code_tokens).uniq { |raw| raw.downcase }.join(" ")
      return "" if candidate.blank?

      question_down = @question.downcase
      tokens = KbDocumentResolver.resolve_scoped(candidate, account: @account)
                                 .flat_map(&:matched_tokens)
                                 .uniq { |token| token.downcase }
                                 .reject { |token| question_down.include?(token.downcase) }
      tokens.join(" ").truncate(ANCHOR_SUFFIX_MAX_CHARS, omission: "")
    end

    def raw_tokens(text)
      text.to_s.scan(KbDocumentResolver::TOKEN_RE).uniq
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
      lines = [
        "## Photo Evidence (this turn)",
        "The technician attached a photo in this same turn and the question refers to it. The fields below were read from the image, not from the knowledge base; use them to interpret the question. Procedures, values and part identity come only from the retrieved manuals."
      ]
      if Rag::GroundedSynthesisFlag.enabled_for?(@account) && document_on_screen_photo?
        lines << "- This photo is a document on a screen, not the equipment. Printed titles are not the manufacturer."
      end
      lines.concat(
        [
          "- Component: #{@photo_value[:canonical_name] || UNKNOWN}",
          "- Manufacturer: #{@photo_value[:manufacturer] || UNKNOWN}",
          "- Model: #{@photo_value[:model_visible] || UNKNOWN}",
          "- Visible text/codes: #{visible_codes}",
          "- Condition: #{@photo_value[:condition] || UNKNOWN}"
        ]
      )
      lines.join("\n").truncate(EVIDENCE_BLOCK_MAX_CHARS, omission: "")
    end

    def document_on_screen_photo?
      codes = visible_code_parts
      return false if codes.empty?

      folded = codes.map { |code| I18n.transliterate(code).downcase }
      return true if DOCUMENT_ON_SCREEN_TITLES.any? { |title| folded.any? { |code| code.include?(title) } }

      has_sheet_title = codes.any? do |code|
        words = I18n.transliterate(code).scan(/[A-Za-z]{2,}/)
        words.size >= 2 && words.any? { |word| word.length >= 4 }
      end
      has_plant_id = codes.any? { |code| code.match?(PLANT_IDENTIFIER_PATTERN) }
      has_sheet_title && has_plant_id
    end
  end
end
