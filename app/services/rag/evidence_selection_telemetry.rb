# frozen_string_literal: true

require "digest"

module Rag
  # Emits the Fase 3 evidence trace through the existing PILOT_USAGE seam.
  # Pure Retrieve calls still do not create BedrockQuery rows.
  class EvidenceSelectionTelemetry
    ABSTENTION_PATTERN = /
      DATA_NOT_AVAILABLE |
      REQUIRES?_FIELD_VERIFICATION |
      El\ documento\ no\ incluye\ este\ dato |
      The\ document\ does\ not\ include\ this\ information |
      requiere\ verificaci[oó]n\ en\ campo |
      requires\ field\ verification
    /ix.freeze

    def self.log(selection:, question:, answer:, generation_mode:, account_id:, user_id:,
                 conversation_session_id:, correlation_id:, sources_visible:)
      new(
        selection: selection,
        question: question,
        answer: answer,
        generation_mode: generation_mode,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        sources_visible: sources_visible
      ).log
    end

    def self.log_route(question:, answer:, generation_mode:, account_id:, user_id:,
                       conversation_session_id:, correlation_id:, retrieval_budget:,
                       expansion_mechanisms:, timings:, outcome:, outcome_reason:,
                       verbatim_directive:, generation_input_tokens:,
                       generation_output_tokens:, generation_prompt_chars:,
                       attribution_dropped: 0, ambiguity_detected: nil,
                       ambiguity_identifier: nil, ambiguity_families: nil)
      mechanisms = Array(expansion_mechanisms)
      PilotUsageLog.log(
        "evidence_route",
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        generation_mode: generation_mode,
        route_taken: generation_mode,
        question_sha256: Digest::SHA256.hexdigest(question.to_s),
        answer_sha256: Digest::SHA256.hexdigest(answer.to_s),
        retrieval_budget: retrieval_budget,
        expansion_used: mechanisms.any?,
        expansion_mechanism: dominant_mechanism(mechanisms),
        abstention: answer.to_s.match?(ABSTENTION_PATTERN),
        outcome: outcome,
        outcome_reason: outcome_reason,
        verbatim_directive: verbatim_directive,
        retrieval_ms: timings[:retrieval_ms],
        expansion_ms: timings[:expansion_ms],
        local_ms: timings[:local_ms],
        generation_ms: timings[:generation_ms],
        generation_chunks: timings[:generation_chunks],
        generation_input_tokens: generation_input_tokens,
        generation_output_tokens: generation_output_tokens,
        generation_prompt_chars: generation_prompt_chars,
        attribution_dropped: attribution_dropped,
        ambiguity_detected: ambiguity_detected,
        ambiguity_identifier: ambiguity_identifier,
        ambiguity_families: ambiguity_families
      )
    end

    def self.dominant_mechanism(mechanisms)
      return :section_identity if mechanisms.include?(:section_identity)
      return :adjacent_page_interim if mechanisms.include?(:adjacent_page_interim)

      :none
    end
    private_class_method :dominant_mechanism

    def initialize(selection:, question:, answer:, generation_mode:, account_id:, user_id:,
                   conversation_session_id:, correlation_id:, sources_visible:)
      @selection = selection
      @question = question.to_s
      @answer = answer.to_s
      @identity = {
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        generation_mode: generation_mode,
        question_sha256: Digest::SHA256.hexdigest(@question),
        answer_sha256: Digest::SHA256.hexdigest(@answer),
        sources_visible: sources_visible
      }
    end

    def log
      PilotUsageLog.log("evidence_selection", **@identity, **summary_fields)
      @selection.contexts.each do |context|
        PilotUsageLog.log(
          "evidence_selection_context",
          **@identity,
          **summary_fields,
          document_id: context.document_id,
          source_uri: context.source_uri,
          page: context.page_number,
          chunk_sha256: context.chunk_sha256,
          excerpt: context.evidence_excerpt.to_s.first(200),
          excerpt_sha256: Digest::SHA256.hexdigest(context.evidence_excerpt.to_s),
          expansion_mechanism: expansion_mechanism_for(context)
        )
      end
      true
    end

    private

    def summary_fields
      @summary_fields ||= {
        resolution_mode: @selection.mode,
        needs_selection: @selection.mode == :ambiguous,
        answered_relations: @selection.answered_relations.to_a.sort,
        abstained_relations: @selection.abstained_relations.to_a.sort,
        insufficient_reason: insufficient_reason,
        contexts_delivered: @selection.contexts.size,
        groups_total: @selection.contexts.map { |context| [ context.section_key, context.board_key ] }.uniq.size,
        selector_version: @selection.selector_version,
        expansion_mechanism: dominant_expansion_mechanism,
        rejection_reasons: rejection_reasons,
        sources_visible: @identity[:sources_visible]
      }
    end

    def insufficient_reason
      Rag::ResolutionPresenter.insufficient_reason(@selection)
    end

    def rejection_reasons
      @selection.rejections.map(&:reason).tally.sort.map { |reason, count| "#{reason}:#{count}" }
    end

    def dominant_expansion_mechanism
      mechanisms = @selection.expansions.map(&:mechanism)
      return :section_identity if mechanisms.include?(:section_identity)
      return :adjacent_page_interim if mechanisms.include?(:adjacent_page_interim)

      :none
    end

    def expansion_mechanism_for(context)
      expansion = @selection.expansions.find { |item| item.neighbor_chunk_sha256 == context.chunk_sha256 }
      expansion&.mechanism || :none
    end
  end
end
