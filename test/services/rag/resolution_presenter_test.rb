# frozen_string_literal: true

require "test_helper"

class Rag::ResolutionPresenterTest < ActiveSupport::TestCase
  test "serializes ambiguous contexts, facts, selection queries, and source visibility" do
    analysis = Rag::QueryEntities.analyze("¿A qué serie corresponde el LED SPM?")
    selection = selection_for(
      mode: :ambiguous,
      contexts: [
        context(label: "HIDRA — TPR50", section: "CARLOS SILVA", page: 9, target: "https://example.test/manual.pdf#page=9"),
        context(label: "SISTEL — TWISTER", section: "SISTEL", page: 89, target: "javascript:alert(1)")
      ]
    )

    visible = Rag::ResolutionPresenter.new(
      selection: selection,
      analysis: analysis,
      question: analysis.question,
      sources_visible: true
    ).call
    hidden = Rag::ResolutionPresenter.new(
      selection: selection,
      analysis: analysis,
      question: analysis.question,
      sources_visible: false
    ).call

    assert_equal "resolution_v1", visible[:contract_version]
    assert_equal "ambiguous", visible[:mode]
    assert_equal true, visible[:needs_selection]
    assert_equal 2, visible[:evidence_cards].size
    assert_equal 9, visible[:evidence_cards].first[:page]
    assert_equal "https://example.test/manual.pdf#page=9", visible[:evidence_cards].first[:evidence_url]
    assert_nil visible[:evidence_cards].second[:evidence_url]
    assert_includes visible[:evidence_cards].first[:select_query], analysis.question
    assert visible[:facts].all? { |fact| fact[:card_id].present? }

    assert hidden[:evidence_cards].all? { |card| card[:page].nil? && card[:evidence_url].nil? }
    assert_equal visible.except(:evidence_cards), hidden.except(:evidence_cards)
  end

  test "maps insufficient rejection reasons without declaring a global absence" do
    analysis = Rag::QueryEntities.analyze("¿A qué serie corresponde el LED ZK5?")
    rejection = Rag::EvidenceSelection::Rejection.new(
      chunk_sha256: "rejected",
      stage: 3,
      reason: :relation_not_documented
    )
    selection = selection_for(mode: :insufficient, contexts: [], rejections: [ rejection ])

    payload = Rag::ResolutionPresenter.new(
      selection: selection,
      analysis: analysis,
      question: analysis.question,
      sources_visible: false
    ).call

    assert_equal "insufficient", payload[:mode]
    assert_equal false, payload[:needs_selection]
    assert_equal "relation_not_documented", payload[:insufficient_reason]
    assert_empty payload[:evidence_cards]
  end

  test "not applicable contract is complete and internally consistent" do
    payload = Rag::ResolutionPresenter.not_applicable

    assert_equal "not_applicable", payload[:mode]
    assert_equal false, payload[:needs_selection]
    assert_equal [], payload[:facts]
    assert_equal [], payload[:evidence_cards]
  end

  private

  def selection_for(mode:, contexts:, rejections: [])
    Rag::EvidenceSelection.new(
      mode: mode,
      contexts: contexts,
      answered_relations: Set.new,
      abstained_relations: Set.new,
      rejections: rejections,
      expansions: [],
      selector_version: "selector-v1"
    )
  end

  def context(label:, section:, page:, target:)
    identifier = Rag::QueryAnalysis::Identifier.new(
      raw: "SPM",
      canonical: "SPM",
      shape: :alpha,
      position: :labelled
    )
    Rag::EvidenceSelection::EvidenceContext.new(
      section_key: section,
      board_key: label,
      label: label,
      breadcrumb: [ label, section, "SEGURIDADES 1.1-1" ],
      document_id: "doc-1",
      source_uri: "s3://bucket/manual.pdf",
      page_number: page,
      evidence_target: target,
      evidence_excerpt: "SPM | SERIE PUERTAS CABINA – EXTERIORES",
      identifiers: [ identifier ],
      relations_covered: Set[:attribution],
      chunk_sha256: "sha-#{page}",
      rank: page,
      match_reason: :direct
    )
  end
end
