# frozen_string_literal: true

ENV["WORDING_MULTILOOKUP_PROBE"] = "require"

require "test_helper"
require Rails.root.join("script/rag_wording_multilookup_probe_2026-09-29.rb")

class WordingMultilookupCauseTest < ActiveSupport::TestCase
  Diagnosis = WordingMultilookupDiagnosis

  OUT = {
    entity: "Seguridad OUT",
    relation: "connection",
    entity_tokens: %w[Seguridad OUT],
    value_label: "23",
    value_tokens: %w[23]
  }.freeze
  IN = {
    entity: "Seguridad IN",
    relation: "connection",
    entity_tokens: %w[Seguridad IN],
    value_label: "24",
    value_tokens: %w[24]
  }.freeze
  INFERIOR = {
    entity: "inferior",
    relation: "connection",
    entity_tokens: %w[inferior],
    value_label: "30",
    value_tokens: %w[30]
  }.freeze
  SUPERIOR = {
    entity: "superior",
    relation: "connection",
    entity_tokens: %w[superior],
    value_label: "31",
    value_tokens: %w[31]
  }.freeze

  test "section 4 words do not cover inferior or superior" do
    chunks = [ { content: "El micro inferior y el micro superior están en la bornera." } ]
    result = Diagnosis.assess(
      chunks: chunks,
      mappings: [ INFERIOR, SUPERIOR ],
      reported_answer: nil,
      frontiers: { route_selected: false }
    )

    assert_equal [ false, false ], result[:mappings].pluck(:covered)
    assert_nil result[:mappings][0][:matched_explicit_evidence]
    assert_not_equal "synthesis", result[:primary_cause]
    assert_equal Diagnosis::ABSENT_ANSWER, result[:reported_answer]
    assert_equal "route eligibility", result[:primary_cause]
  end

  test "an OUT row does not cover Seguridad IN" do
    chunks = [ { content: "| 23 | SEGURIDAD OUT |" } ]
    result = Diagnosis.assess(
      chunks: chunks,
      mappings: [ OUT, IN ],
      reported_answer: nil,
      frontiers: { route_selected: false }
    )

    assert result[:mappings][0][:covered]
    assert_equal "23", result[:mappings][0][:value]
    assert_equal "| 23 | SEGURIDAD OUT |", result[:mappings][0][:matched_explicit_evidence]
    assert_not result[:mappings][1][:covered]
    assert_nil result[:mappings][1][:matched_explicit_evidence]
    assert_not_equal "synthesis", result[:primary_cause]
  end

  test "associations present and an answer that does not state them are synthesis" do
    chunks = [ { content: "| 23 | SEGURIDAD OUT |\n| 24 | SEGURIDAD IN |" } ]
    result = Diagnosis.assess(
      chunks: chunks,
      mappings: [ OUT, IN ],
      reported_answer: "La bornera tiene varias señales de seguridad.",
      frontiers: { route_selected: true }
    )

    assert result[:mappings].all? { |mapping| mapping[:covered] }
    assert_equal "synthesis", result[:primary_cause]
    assert_equal "La bornera tiene varias señales de seguridad.", result[:reported_answer]
  end

  test "a later designator beside its value is expressed when an earlier value word is far" do
    chunks = [ { content: "| F1 | FOTOCELULA EMBARQUE 1 |\n| F2 | FOTOCELULA EMBARQUE 2 |" } ]
    answer = <<~TEXT
      **Embarque 1:** "FOTOCELULA EMBARQUE 1" [2]

      **Embarque 2:** "FOTOCELULA EMBARQUE 2" [2]

      Estas fotocélulas se identifican también en la tabla de indicadores LED del diagrama como:

      - LED F1 — "FOTOCELULA EMBARQUE 1" [2]
      - LED F2 — "FOTOCELULA EMBARQUE 2" [2]
    TEXT
    mappings = [
      { entity: "F1", relation: "attribution", entity_tokens: %w[F1], open_value: true, value_excludes: %w[F1 F2 EDEL K2] },
      { entity: "F2", relation: "attribution", entity_tokens: %w[F2], open_value: true, value_excludes: %w[F1 F2 EDEL K2] }
    ]
    result = Diagnosis.assess(
      chunks: chunks,
      mappings: mappings,
      reported_answer: answer,
      frontiers: { route_selected: true }
    )

    assert result[:mappings].all? { |mapping| mapping[:covered] }
    assert_equal "none", result[:primary_cause]
  end

  test "an answer that states both borne associations is not synthesis" do
    chunks = [ { content: "| 23 | SEGURIDAD OUT |\n| 24 | SEGURIDAD IN |" } ]
    answer = "Seguridad OUT va al borne 23 y Seguridad IN va al borne 24."
    result = Diagnosis.assess(
      chunks: chunks,
      mappings: [ OUT, IN ],
      reported_answer: answer,
      frontiers: { route_selected: true }
    )

    assert_equal "none", result[:primary_cause]
    assert_equal answer, result[:reported_answer]
  end

  test "a contradicting explicit value without the oracle is source representation" do
    chunks = [ { content: "| 13 | SEGURIDAD OUT |" } ]
    result = Diagnosis.assess(
      chunks: chunks,
      mappings: [ OUT ],
      reported_answer: nil,
      frontiers: { route_selected: false }
    )

    assert_not result[:mappings][0][:covered]
    assert_equal "source/chunk representation", result[:primary_cause]
    assert_equal Diagnosis::ABSENT_ANSWER, result[:reported_answer]
  end

  test "explicit assignment lines match the route predicate" do
    route = Rag::StructuredEvidenceRoute.allocate
    lines = [
      "| 23 | SEGURIDAD OUT |",
      "| 30 | MICRO NIVEL INFERIOR |",
      "El micro inferior y el micro superior están en la bornera.",
      "ACTION: SEGURIDAD OUT — señales",
      "| K1 | Contactor 24VAC SUBE |"
    ]
    lines.each do |line|
      assert_equal route.send(:explicit_assignment_line?, line), Diagnosis.explicit_assignment_line?(line), line
    end
  end

  test "anchor phrase keeps turn tokens and drops the function-word list" do
    borne = Diagnosis.anchor_phrase("¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?")
    location = Diagnosis.anchor_phrase("¿Dónde está conectada Seguridad IN en la bornera del tablero?")
    micro = Diagnosis.anchor_phrase("¿A qué borne corresponde el micro de nivel inferior?")

    assert_equal "bornes Seguridad OUT Seguridad IN", borne
    assert_equal "conectada Seguridad IN bornera tablero", location
    assert_equal "borne corresponde micro nivel inferior", micro
    [ borne, location, micro ].each do |phrase|
      assert_not_equal phrase.squish.downcase, "¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?".squish.downcase
    end
    assert_not phrase_same?(borne, "¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?")
    assert_not phrase_same?(location, "¿Dónde está conectada Seguridad IN en la bornera del tablero?")
  end

  private

  def phrase_same?(left, right)
    left.to_s.squish.casecmp?(right.to_s.squish)
  end
end
