# frozen_string_literal: true

module Rag
  # Resolves generic LED/lock/safety-contact questions without asking a blind
  # clarification. A single Retrieve call inspects the available evidence. When
  # it spans several documented manufacturer/model pairs, the responder shows
  # three concrete choices and lets the technician narrow the next query.
  class AmbiguousModelResponder
    MIN_DISTINCT_MODELS = 3
    RETRIEVAL_RESULTS = 8
    MAX_OPTIONS = 3

    MANUFACTURERS = %w[
      ALTIUS ORONA KONE OTIS SCHINDLER SOPREL THYSSEN THYSSENKRUPP TOKIBAT
    ].freeze
    MODEL_PATTERN =
      /\b(?:[A-Z]{2,}\d+[A-Z0-9.-]*|[A-Z]{2,}(?:-[A-Z0-9]+)+)\b/.freeze

    def self.build(question:, account:, entity_s3_uris:, entity_sources:, force_entity_filter:,
                   response_locale: nil)
      return unless DeterministicIntent.ambiguous_hardware_query?(question)

      new(
        question: question,
        account: account,
        entity_s3_uris: entity_s3_uris,
        entity_sources: entity_sources,
        force_entity_filter: force_entity_filter,
        response_locale: response_locale
      )
    end

    def initialize(question:, account:, entity_s3_uris:, entity_sources:, force_entity_filter:,
                   response_locale: nil, rag_service: nil)
      @question = question
      @account = account
      @service = rag_service || BedrockRagService.new(account: account)
      @entity_s3_uris = Array(entity_s3_uris)
      @entity_sources = Array(entity_sources)
      @force_entity_filter = force_entity_filter
      @locale = response_locale.presence&.to_sym || I18n.locale
    end

    def execute
      retrieval = @service.retrieve_chunks(
        @question,
        entity_s3_uris: @entity_s3_uris,
        entity_sources: @entity_sources,
        force_entity_filter: @force_entity_filter,
        number_of_results: RETRIEVAL_RESULTS,
        account_id: @account&.id
      )
      candidates = candidates_from(retrieval[:chunks])
      return if candidates.size < MIN_DISTINCT_MODELS

      selected = candidates.first(MAX_OPTIONS)
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

        manufacturer = metadata["manufacturer"].presence || explicit_manufacturer(searchable)
        model = metadata["controller_model"].presence ||
          metadata["board_model"].presence ||
          searchable.scan(MODEL_PATTERN).first
        label =
          if manufacturer.present? && model.present?
            "#{manufacturer} — #{model}"
          else
            heading_label(chunk[:content])
          end
        next if label.blank?

        key = label.downcase
        next if seen[key]

        seen[key] = true
        { label: label, chunk: chunk }
      end
    end

    def explicit_manufacturer(text)
      normalized = text.to_s.upcase
      MANUFACTURERS.find { |manufacturer| normalized.match?(/\b#{Regexp.escape(manufacturer)}\b/) }
    end

    def heading_label(content)
      heading = content.to_s.lines.find { |line| line.match?(/\A##\s+/) }
      return if heading.blank?

      label = heading
        .sub(/\A##\s+/, "")
        .sub(/\A(?:S\d+\s+[—–-]\s+)?(?:DIAGRAM|SAFETY SYSTEM):\s*/i, "")
        .split(/\s+[—–]\s+(?=(?:Diagrama|Esquema|Conex|Seguridad|Cadena)\b)/i, 2)
        .first
        .split(/\s+\/\s+/, 2)
        .first
        .strip
      return if label.blank? || label.casecmp?("PIPELINE_INJECTED")

      label.first(80)
    end

    def render_answer(candidates)
      options = candidates.each_with_index.map { |candidate, index| "#{index + 1}. #{candidate[:label]}" }
      [
        I18n.t("rag.ambiguous_model_prompt", locale: @locale),
        options.join("\n")
      ].join("\n\n")
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
