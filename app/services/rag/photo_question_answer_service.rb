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
  #   - The "Photo Evidence" session_context block tells generation what was
  #     read off the image. Procedures and values still come only from the
  #     retrieved manuals. When the question names a brand and the photo
  #     shows a different component, the block tells generation to say that
  #     mismatch first and not apply that brand, or another manufacturer, to
  #     the photographed part. "# NO MATCH" in generation.txt still applies.
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
    # Header, optional mismatch, hidden-target, and screen lines, then five fields.
    # 1100 keeps the mismatch line, the hidden-target line, and Condition.
    EVIDENCE_BLOCK_MAX_CHARS = 1100
    UNKNOWN = "UNKNOWN"
    # H9: laptop-screen capture of a sheet. Accent-folded titles; plant pattern
    # is 4+ uppercase letters + digits. No site name is hardcoded (D10).
    DOCUMENT_ON_SCREEN_TITLES = [
      "caracteristicas motor",
      "fijacion de cables"
    ].freeze
    PLANT_IDENTIFIER_PATTERN = /\b[A-Z]{4,}\s+\d{2,}\b/

    def initialize(question:, evidence_value:, session:, account:, user_id:, correlation_id:, locale:, field_photo_id: nil, accepted_observation: nil, session_context_snapshot: nil, entity_s3_uris_snapshot: nil, retrieval_question: nil, equipment_identity: nil)
      @question = question.to_s.strip
      @evidence = evidence_value.to_h.deep_symbolize_keys
      @session = session
      @account = account
      @user_id = user_id
      @correlation_id = correlation_id
      @locale = locale.to_s.presence&.to_sym
      @field_photo_id = field_photo_id
      @accepted_observation = accepted_observation
      @session_context_snapshot = session_context_snapshot
      @entity_s3_uris_snapshot = entity_s3_uris_snapshot
      @retrieval_question = retrieval_question.to_s.strip.presence
      @equipment_identity = equipment_identity
    end

    attr_reader :equipment_identity, :retrieval_question

    # @return [Hash, nil] { answer:, citations:, generation_mode: } or nil when
    #   the flag is off, the question is blank, or the RAG call did not succeed.
    def call
      return nil unless Rag::PhotoQuestionFlag.enabled?
      return nil if @question.blank?

      input = retrieval_input
      result = execute_rag_query(
        input,
        retrieval_question: (@retrieval_question.present? ? input : nil),
        session_context: merged_session_context,
        entity_s3_uris:  turn_entity_s3_uris,
        account:         @account,
        user_id:         @user_id,
        response_locale: @locale,
        correlation_id:  @correlation_id,
        conversation_session_id: @session&.id,
        # The visual decision already ran. This retrieve must not open another one.
        # The N2 snapshot is the identity for this turn. Do not pass conv_session.
        apply_photo_continuity: false,
        equipment_identity: @equipment_identity
      )
      return nil unless result.success?
      return unavailable_photo_lookup(result) if result.equipment_identity_status.to_s == "unavailable"

      processor       = Bedrock::CitationProcessor.new
      raw_citations   = processor.transport_references(result.citations)
      # Same rule as RagController#ask: bands are fixed before sources are hidden.
      # Provenance uses the accepted observation captured for this turn.
      # It does not re-read FieldPhoto.visual_observation after generation.
      segments        = Rag::ProvenanceSegmenter.call(
        answer: result.answer,
        citations: raw_citations,
        visual_observation: @accepted_observation
      )
      sources_visible = Rag::SourcesVisibility.enabled?
      answer          = sources_visible ? result.answer : processor.strip_resolved_markers(result.answer, raw_citations)

      {
        answer: answer,
        citations: sources_visible ? raw_citations : [],
        provenance_segments: segments,
        retrieved_citations: result.retrieved_citations,
        effective_query: result.effective_question,
        generation_mode: result.generation_mode
      }
    end

    private

    # Retrieval could not run. The paid vision reading stays on the job's
    # failed path. The copy is the existing photo-question failure, not a
    # companion answer.
    def unavailable_photo_lookup(result)
      unavailable = I18n.with_locale(@locale) { I18n.t("rag.photo_question_unavailable") }
      {
        answer: unavailable,
        citations: [],
        provenance_segments: Rag::ProvenanceSegmenter.call(answer: unavailable, citations: []),
        retrieved_citations: [],
        generation_mode: result.generation_mode,
        failed: true,
        equipment_identity_status: "unavailable"
      }
    end

    # Snapshot text when the turn already composed one. The catalog suffix
    # still appends, the same way it does for a literal photo question.
    def retrieval_input
      return anchored_question if @retrieval_question.blank?

      suffix = anchor_suffix
      suffix.present? ? "#{@retrieval_question} (#{suffix})" : @retrieval_question
    end

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
      return "" if @evidence[:relevance_to_goal].to_s == "unrelated"
      return "" unless @account

      identity = [ known(@evidence[:canonical_name]), known(@evidence[:model_visible]) ].compact.join(" ")
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
      Array(@evidence[:visible_codes]).map { |code| known(code) }.compact
    end

    def known(value)
      text = value.to_s.strip
      return nil if text.blank? || text.casecmp(UNKNOWN).zero?

      text
    end

    # A caller-supplied snapshot is the work context captured with the [FOTO]
    # ownership write. nil means this call is outside that gate and may read
    # the session, which direct script callers still do.
    def merged_session_context
      base = @session_context_snapshot.nil? ? SessionContextBuilder.build(@session) : @session_context_snapshot.to_s
      [ base.presence, photo_evidence_block ].compact.join("\n\n")
    end

    # Pinned-document URIs from the same capture. nil keeps the live Focus
    # read for callers that did not pass a snapshot. An empty list is a
    # captured "no pins" result and is not replaced by a later read.
    def turn_entity_s3_uris
      return SessionContextBuilder.entity_s3_uris(@session) if @entity_s3_uris_snapshot.nil?

      @entity_s3_uris_snapshot
    end

    def photo_evidence_block
      visible_codes = Array(@evidence[:visible_codes]).presence&.join(", ") || UNKNOWN
      lines = [
        "## Photo Evidence (this turn)",
        "The technician attached a photo in this same turn and the question refers to it. The fields below were read from the image, not from the knowledge base; UNKNOWN means the photo does not show it and is never printed. Open the answer with one or two sentences on what the photo shows, then answer the question. Procedures and values come only from the retrieved manuals."
      ]
      lines << hidden_target_line if @evidence[:target_visible] == false
      lines << brand_component_mismatch_line if brand_component_mismatch?
      if Rag::GroundedSynthesisFlag.enabled_for?(@account) && document_on_screen_photo?
        lines << "- This photo is a document on a screen, not the equipment. Printed titles are not the manufacturer."
      end
      lines.concat(
        [
          "- Component: #{@evidence[:canonical_name] || UNKNOWN}",
          "- Manufacturer: #{@evidence[:manufacturer] || UNKNOWN}",
          "- Model: #{@evidence[:model_visible] || UNKNOWN}",
          "- Visible text/codes: #{visible_codes}",
          "- Condition: #{@evidence[:condition] || UNKNOWN}"
        ]
      )
      lines.join("\n").truncate(EVIDENCE_BLOCK_MAX_CHARS, omission: "")
    end

    def hidden_target_line
      missing = @evidence[:missing_view_or_detail].to_s.squish
      detail = missing.present? ? " (#{missing})" : ""
      "- Vision judged that this photo does not show what the question asks about#{detail}. Say that first, then answer; do not treat the photographed component as the asked one."
    end

    def brand_component_mismatch?
      asked = brands_in(@question)
      return false if asked.empty?
      return false if (asked & brands_in(known(@evidence[:manufacturer]).to_s)).any?

      component = known(@evidence[:canonical_name])
      return false if component.blank?

      (content_tokens(component) & (content_tokens(@question) - asked)).empty?
    end

    def brand_component_mismatch_line
      "The brand named in the question was not read on this photo, and the photographed component is not the component asked about. Say that mismatch first. Do not apply that brand's procedure, or a fragment from another manufacturer, to the photographed component."
    end

    def brands_in(text)
      content_tokens(text).select { |token| KbDocumentResolver::BRANDS.include?(token) }
    end

    def content_tokens(text)
      I18n.transliterate(text.to_s).downcase.scan(/[a-z0-9]{4,}/)
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
