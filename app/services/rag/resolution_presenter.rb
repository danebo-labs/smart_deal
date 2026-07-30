# frozen_string_literal: true

module Rag
  # Serializes EvidenceSelection into the closed resolution_v1 browser contract.
  # It does not choose evidence or alter the technical answer.
  class ResolutionPresenter
    CONTRACT_VERSION = "resolution_v1"

    def self.not_applicable
      {
        contract_version: CONTRACT_VERSION,
        mode: "not_applicable",
        needs_selection: false,
        answered_relations: [],
        abstained_relations: [],
        insufficient_reason: nil,
        facts: [],
        evidence_cards: []
      }
    end

    def self.insufficient_reason(selection)
      return nil unless selection.mode == :insufficient

      reasons = selection.rejections.map(&:reason)
      return "identifier_not_in_evidence" if reasons.include?(:identifier_not_in_evidence)
      return "relation_not_documented" if reasons.include?(:relation_not_documented)
      return "function_without_identifier" if reasons.include?(:function_without_identifier)

      "no_candidate_retrieved"
    end

    def initialize(selection:, analysis:, question:, sources_visible:)
      @selection = selection
      @analysis = analysis
      @question = question.to_s
      @sources_visible = sources_visible
    end

    def call
      cards = @selection.contexts.each_with_index.map { |context, index| card(context, index + 1) }
      {
        contract_version: self.class::CONTRACT_VERSION,
        mode: @selection.mode.to_s,
        needs_selection: @selection.mode == :ambiguous,
        answered_relations: @selection.answered_relations.to_a.map(&:to_s).sort,
        abstained_relations: @selection.abstained_relations.to_a.map(&:to_s).sort,
        insufficient_reason: self.class.insufficient_reason(@selection),
        facts: facts(cards),
        evidence_cards: cards
      }
    end

    private

    def card(context, ordinal)
      {
        id: "c#{ordinal}",
        label: context.label.to_s,
        breadcrumb: Array(context.breadcrumb).map(&:to_s).compact_blank,
        excerpt: context.evidence_excerpt.to_s.first(200),
        select_query: select_query(context),
        page: @sources_visible ? context.page_number : nil,
        evidence_url: @sources_visible ? safe_evidence_target(context.evidence_target) : nil
      }
    end

    def select_query(context)
      return nil unless @selection.mode == :ambiguous

      "#{@question}\n#{I18n.t('rag.model_selection_query', model: context.label)}"
    end

    def safe_evidence_target(value)
      uri = URI.parse(value.to_s)
      uri.to_s if uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      nil
    end

    def facts(cards)
      @selection.contexts.each_with_index.flat_map do |context, index|
        relations = fact_relations(context)
        context.identifiers.flat_map do |identifier|
          relations.map do |relation|
            {
              identifier: identifier.raw,
              relation: relation.to_s,
              value: context.evidence_excerpt.to_s.first(200),
              card_id: cards.fetch(index).fetch(:id)
            }
          end
        end
      end
    end

    def fact_relations(context)
      requested = @analysis.requested_relation
      covered = context.relations_covered
      requested.present? ? requested & covered : covered
    end
  end
end
