# frozen_string_literal: true

# Aggregates per-page visual-triage verdicts (PageRelevanceFilter's extended Haiku
# schema, docs/rag/plan_conocimiento_visual.md Fase 1) into a document-level class,
# and turns a set of geometric-complexity candidate pages into a bounded, ranked
# escalation plan for FileMultimodalRouter.
#
# Pure aggregation: no LLM calls, no PDF reads. Consumes data already produced by
# PageRelevanceFilter (per-page verdicts) and FileMultimodalRouter (candidate pages).
class DocumentClassProfile
  DOCUMENT_CLASSES = %i[text_manual visual_technical mixed photo_set].freeze

  # Historical target from ContractualLimits::MANUAL[:max_opus_page_fraction]'s own
  # comment ("<15%, not yet enforced"). NOT the same constant: that one is Gate 9's
  # billing worst-case assumption (pinned at 1.0 by test/services/contractual_limits_test.rb)
  # and is out of scope for this flag. This is the triage feature's own, independent
  # default budget, pending the human authorization tracked in the plan's "Decisiones
  # humanas pendientes" — see hallazgo I-02.
  DEFAULT_MAX_OPUS_PAGE_FRACTION = 0.15

  # Below this fraction of kept pages carrying any visual signal, the document is
  # treated as plain text — the triage fields are noise, not signal.
  VISUAL_PAGE_FRACTION_FLOOR = 0.10
  # At/above this fraction of visual pages that also carry drawn relations, the
  # document's information is relational (wiring/schematics), not just photos.
  RELATIONAL_PAGE_FRACTION_FLOOR = 0.30
  # Above this average small-component count on visual pages without much relation
  # coverage, the document reads as an inventory of photographed parts.
  PHOTO_SET_MIN_AVG_COMPONENTS = 3.0

  Result = Struct.new(:document_class, :visual_page_fraction, :relational_page_fraction,
                       :avg_component_count, :page_count, keyword_init: true)

  # @param page_verdicts [Hash{Integer => Hash}] page_number => verdict with
  #   :keep, :visual_complexity ("none"|"moderate"|"high"), :has_visual_relations,
  #   :component_count. A verdict missing a field is treated as :none/false/0 —
  #   the same degradation PageRelevanceFilter applies when Haiku omits a field.
  # @return [Result]
  def self.classify(page_verdicts:)
    kept = page_verdicts.values.select { |v| v[:keep] != false }

    if kept.empty?
      return Result.new(document_class: :text_manual, visual_page_fraction: 0.0,
                         relational_page_fraction: 0.0, avg_component_count: 0.0, page_count: 0)
    end

    visual     = kept.select { |v| visual_page?(v) }
    relational = visual.select { |v| v[:has_visual_relations] == true }

    visual_fraction     = visual.size.to_f / kept.size
    relational_fraction = visual.empty? ? 0.0 : relational.size.to_f / visual.size
    avg_components      = visual.empty? ? 0.0 : visual.sum { |v| v[:component_count].to_i }.to_f / visual.size

    Result.new(
      document_class:           resolve_class(visual_fraction, relational_fraction, avg_components),
      visual_page_fraction:     visual_fraction,
      relational_page_fraction: relational_fraction,
      avg_component_count:      avg_components,
      page_count:               kept.size
    )
  end

  # Ranks geometric-complexity candidates and returns the page numbers authorized
  # to escalate to Opus under an explicit budget, highest complexity first. Pages
  # that already escalate through the pre-existing scanned-page gate must NOT be
  # included in `candidates` — that gate is unconditional and predates this budget.
  #
  # @param candidates [Array<Hash>] each {page_number:, complexity_score:}
  # @param total_pages [Integer] document page count (the fraction's denominator)
  # @param max_opus_page_fraction [Float] 0.0–1.0
  # @return [Set<Integer>] page numbers authorized to escalate
  def self.select_escalation_pages(candidates:, total_pages:, max_opus_page_fraction:)
    return Set.new if candidates.blank? || total_pages.to_i <= 0

    budget = (total_pages.to_i * max_opus_page_fraction.to_f).floor
    return Set.new if budget <= 0

    candidates
      .sort_by { |c| -c[:complexity_score].to_i }
      .first(budget)
      .pluck(:page_number)
      .to_set
  end

  def self.visual_page?(verdict)
    (verdict[:visual_complexity] || :none).to_s != "none" || verdict[:has_visual_relations] == true
  end
  private_class_method :visual_page?

  def self.resolve_class(visual_fraction, relational_fraction, avg_components)
    return :text_manual if visual_fraction < VISUAL_PAGE_FRACTION_FLOOR
    return :visual_technical if relational_fraction >= RELATIONAL_PAGE_FRACTION_FLOOR
    return :photo_set if avg_components >= PHOTO_SET_MIN_AVG_COMPONENTS

    :mixed
  end
  private_class_method :resolve_class
end
