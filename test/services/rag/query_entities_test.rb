# frozen_string_literal: true

require "test_helper"

# Locks the variant-normalization spec in
# docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md §3 (the "Fila Sonnet de Fase 1"
# handoff). Three corpus variants must unify; four folds are explicitly prohibited,
# each protecting a real gate case.
class Rag::QueryEntitiesTest < ActiveSupport::TestCase
  test "EM4000 and EM 4000 fold to the same key" do
    assert_equal Rag::QueryEntities.normalize("EM4000").key,
      Rag::QueryEntities.normalize("EM 4000").key
  end

  test "TPR50 and TPR-50 fold to the same key" do
    assert_equal Rag::QueryEntities.normalize("TPR50").key,
      Rag::QueryEntities.normalize("TPR-50").key
  end

  test "TOKIBAT 2007 and TOKIBAT – 2.007 fold to the same key" do
    assert_equal Rag::QueryEntities.normalize("TOKIBAT 2007").key,
      Rag::QueryEntities.normalize("TOKIBAT – 2.007").key
  end

  # Prohibition 1: never fold digits into each other (em4000_obstaculo_conectores).
  test "CN7, CN8 and CN9 stay distinct" do
    keys = [ "CN7", "CN8", "CN9" ].map { |raw| Rag::QueryEntities.normalize(raw).key }
    assert_equal keys.uniq, keys
  end

  # Prohibition 2: never fold away the trailing letter+digit suffix (EDEL-K2 vs K3 gate).
  test "EDEL-K2 and EDEL-K3 stay distinct" do
    assert_not_equal Rag::QueryEntities.normalize("EDEL-K2").key,
      Rag::QueryEntities.normalize("EDEL-K3").key
  end

  # Prohibition 3: a dot between a digit run and a letter run is not a thousands
  # separator and must survive (mr08_sci connector regression).
  test "CN-112.SC keeps its dot" do
    normalized = Rag::QueryEntities.normalize("CN-112.SC")
    assert_equal "CN112.SC", normalized.key
  end

  # Prohibition 4: a version suffix is never absorbed into the base model — it becomes
  # a distinct `variant` under the same `model_key`, so EM4000 V1 never merges facts
  # with plain EM4000.
  test "EM4000 V1 shares model_key with EM4000 but keeps a distinct variant" do
    plain = Rag::QueryEntities.normalize("EM4000")
    versioned = Rag::QueryEntities.normalize("EM4000 V1")

    assert_equal plain.model_key, versioned.model_key
    assert_nil plain.variant
    assert_equal "V1", versioned.variant
    assert_not_equal plain.key, versioned.key
  end

  test "normalize preserves raw for display" do
    normalized = Rag::QueryEntities.normalize("TPR-50")
    assert_equal "TPR-50", normalized.raw
  end

  # §4: identifiers are taken by shape and position, not by syntactic family (H1 of
  # Fase 0.5) — these are the letter-only codes IDENTIFIER_PATTERN misses entirely.
  test "letter-only codes are extracted as identifiers" do
    question = "¿Qué indican los LEDs SPM, SPH, SEG, SCE, SCC, SSH, AP, SPE y PP?"
    canonicals = Rag::QueryEntities.identifiers(question).map(&:canonical)

    assert_equal %w[SPM SPH SEG SCE SCC SSH AP SPE PP], canonicals
  end

  # §4: a bare numeric token ("37", "12") only counts as an identifier when it is
  # :labelled — this is EDEL-K3's case from the manual (H1 numeric-code gap).
  test "labelled numeric codes from EDEL-K3 are extracted as identifiers" do
    question = "En EDEL-K3, ¿qué indican los LEDs 37, 39 y 41?"
    numeric = Rag::QueryEntities.identifiers(question).select { |i| i.shape == :numeric }

    assert_equal %w[37 39 41], numeric.map(&:canonical)
    assert numeric.all? { |i| i.position == :labelled }
  end

  # Same rule, ENIER MXL1's case: the label term repeats before each number.
  test "labelled numeric codes from ENIER MXL1 are extracted as identifiers" do
    question = "En ENIER MXL1, ¿qué serie indica el LED 12 y qué serie indica el LED 19?"
    numeric = Rag::QueryEntities.identifiers(question).select { |i| i.shape == :numeric }

    assert_equal %w[12 19], numeric.map(&:canonical)
    assert numeric.all? { |i| i.position == :labelled }
  end

  # Negative controls (§4): a bare number is never an identifier on its own — without
  # this guard "p. 31", "24 V" and "3 pasos" would all read as identifiers.
  test "page references, unit values and step counts are not identifiers" do
    assert_empty Rag::QueryEntities.identifiers("p. 31")
    assert_empty Rag::QueryEntities.identifiers("24 V")
    assert_empty Rag::QueryEntities.identifiers("3 pasos")
  end

  # F4: requested_relation is a Set<Symbol>, and a question asking for attribution
  # ("indica") and state ("cuándo se enciende") in the same breath returns both.
  test "a question requesting attribution and state returns both relations" do
    question = "En TOKIBAT 2007, ¿qué indica el LED DL27 y cuándo se enciende?"

    assert_equal Set[:attribution, :state], Rag::QueryEntities.requested_relation(question)
  end

  test "analyze builds a QueryAnalysis with identifiers and requested_relation set" do
    analysis = Rag::QueryEntities.analyze("¿A qué serie corresponde el LED SPM?")

    assert_instance_of Rag::QueryAnalysis, analysis
    assert_equal Set[:attribution], analysis.requested_relation
    assert_includes analysis.identifiers.map(&:canonical), "SPM"
    assert_equal "¿A qué serie corresponde el LED SPM?", analysis.question
  end
end
