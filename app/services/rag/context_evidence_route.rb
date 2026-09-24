# frozen_string_literal: true

module Rag
  # One Retrieve on the short projection, a body filter, then one generation
  # on the original question. retrieve_and_generate cannot do that split: it
  # generates before the references are visible.
  class ContextEvidenceRoute
    def self.build(question:, account:, entity_s3_uris:, entity_sources:, response_locale:,
                   output_channel:, account_id: nil, user_id: nil, conversation_session_id: nil,
                   correlation_id: nil, episode: nil, session_context: nil, rag_service: nil,
                   generator: nil, expander: nil)
      return nil unless output_channel.to_s == "web"
      return nil if Array(entity_s3_uris).any?
      return nil unless ContextProjection.applicable?(question)

      new(
        question: question,
        account: account,
        entity_sources: entity_sources,
        response_locale: response_locale,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        episode: episode,
        session_context: session_context,
        rag_service: rag_service,
        generator: generator,
        expander: expander
      )
    end

    # The block PhotoQuestionAnswerService writes for a photo-with-question
    # turn. It is the only part of the session context this route reads
    # (CG-D19: the photo reading opens the prose of the single answer).
    PHOTO_EVIDENCE_HEADING = "## Photo Evidence (this turn)"

    def self.photo_evidence_block(session_context)
      text = session_context.to_s
      start = text.index(PHOTO_EVIDENCE_HEADING)
      return nil if start.nil?

      block = text[start..]
      next_section = block.index(/\n## /, PHOTO_EVIDENCE_HEADING.length)
      (next_section ? block[0...next_section] : block).strip.presence
    end

    def initialize(question:, account:, entity_sources:, response_locale:, account_id: nil,
                   user_id: nil, conversation_session_id: nil, correlation_id: nil,
                   episode: nil, session_context: nil, rag_service: nil, generator: nil, expander: nil)
      @question = question.to_s
      @account = account
      @entity_sources = Array(entity_sources)
      @response_locale = response_locale
      @account_id = account_id || account&.id
      @user_id = user_id
      @conversation_session_id = conversation_session_id
      @correlation_id = correlation_id
      @episode = ActiveEpisode.parse(episode)
      @photo_evidence = self.class.photo_evidence_block(session_context)
      @rag_service = rag_service || BedrockRagService.new(account: account)
      @generator = generator
      @expander = expander
    end

    def execute
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      retrieval = retrieve_projection
      return retrieval if retrieval.is_a?(StructuredEvidenceRoute::Outcome)

      retrieval_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      kept = Array(retrieval[:chunks]).select { |chunk| ContextChunkFilter.keep?(@question, chunk) }
      stack.complete_from_retrieval(retrieval.merge(chunks: kept), retrieval_ms: retrieval_ms)
    end

    private

    def stack
      StructuredEvidenceRoute.new(
        question: @question,
        account: @account,
        entity_s3_uris: [],
        entity_sources: @entity_sources,
        force_entity_filter: false,
        response_locale: @response_locale,
        account_id: @account_id,
        user_id: @user_id,
        conversation_session_id: @conversation_session_id,
        correlation_id: @correlation_id,
        rag_service: @rag_service,
        generator: episode_aware_generator,
        expander: @expander,
        episode: @episode,
        route_taken: "context_evidence_route"
      )
    end

    def episode_aware_generator
      fields = closed_fact_fields
      return @generator if fields.empty? && @photo_evidence.blank?

      ClosedFactGenerator.new(@generator || AiProvider.new, fields, preface: @photo_evidence)
    end

    def closed_fact_fields
      @episode.facts.filter_map do |field, fact|
        field if ActiveEpisode::STATUSES.include?(fact["status"])
      end
    end

    def retrieve_projection
      @rag_service.retrieve_chunks(
        ContextProjection.search_text(@question),
        entity_s3_uris: [],
        entity_sources: @entity_sources,
        force_entity_filter: false,
        number_of_results: RagRetrievalProfile::OPEN_RESULTS,
        account_id: @account_id,
        correlation_id: @correlation_id,
        route_taken: "context_evidence_route"
      )
    rescue BedrockRagService::BedrockServiceError, StandardError => e
      Rails.logger.warn("Rag::ContextEvidenceRoute: retrieve failed — #{e.class}: #{e.message}")
      StructuredEvidenceRoute::Outcome.new(status: :unavailable, result: nil)
    end

    # The context-evidence route owns its own generation prompt and does not
    # receive SessionContextBuilder's Active Field Problem block. Keep the
    # episode contract local to this route, and enforce the no-repeat rule on
    # the generated text as a backstop rather than relying on prompt obedience.
    # `preface` is the Photo Evidence block of this turn, when there is one.
    class ClosedFactGenerator
      FIELD_TERMS = {
        "manufacturer" => %w[marca fabricante brand manufacturer],
        "model" => %w[modelo model],
        "fault_code" => %w[código codigo error code]
      }.freeze

      def initialize(generator, fields, preface: nil)
        @generator = generator
        @fields = fields
        @preface = preface
      end

      def query(prompt, **kwargs)
        answer = @generator.query([ @preface, directive, prompt ].compact_blank.join("\n\n"), **kwargs)
        remove_repeated_questions(answer.to_s)
      end

      private

      def directive
        return nil if @fields.empty?

        names = @fields.join(", ")
        <<~DIRECTIVE.strip
          Active episode rule: the technician has already closed these fields: #{names}.
          Do not ask for any of them again. A field confirmed unavailable stays unavailable;
          state which documentary detail is missing for a procedure without requesting the closed field.
        DIRECTIVE
      end

      def remove_repeated_questions(text)
        terms = @fields.flat_map { |field| FIELD_TERMS.fetch(field, []) }.uniq
        return text if terms.empty?

        field_pattern = terms.map { |term| Regexp.escape(term) }.join("|")
        filtered = text
          .gsub(/¿[^?\n]*(?:#{field_pattern})[^?\n]*\?/i, "")
          .gsub(/(?:\A|(?<=[.!]))\s*[^?\n]*(?:#{field_pattern})[^?\n]*\?/i, "")
        filtered.gsub(/\n{3,}/, "\n\n").strip
      end
    end
  end
end
