# frozen_string_literal: true

require "test_helper"

class Rag::CitationMarkerNormalizerTest < ActiveSupport::TestCase
  setup do
    @original_flag = ENV.fetch("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED", nil)
    ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = "true"
  end

  teardown do
    if @original_flag.nil?
      ENV.delete("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED")
    else
      ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = @original_flag
    end
  end

  test "normalizes all markers against one evidence block" do
    answer = "Primera [1]. Segunda [2]. Tercera [3]."

    normalized = normalize(answer, evidence_count: 1)

    assert_equal "Primera [1]. Segunda [1]. Tercera [1].", normalized
  end

  test "collapses adjacent normalized markers" do
    assert_equal "Dato [1].", normalize("Dato [2][3].", evidence_count: 1)
  end

  test "collapses space-separated normalized markers" do
    assert_equal "Dato [1].", normalize("Dato [2] [3].", evidence_count: 1)
  end

  test "keeps already valid single-context markers byte identical" do
    answer = "Dato [1]."

    assert_equal answer, normalize(answer, evidence_count: 1)
  end

  test "does not normalize an ambiguous marker with multiple contexts" do
    answer = "Dato [3]."

    assert_equal answer, normalize(answer, evidence_count: 2)
  end

  test "does not normalize with zero contexts" do
    answer = "Dato [2]."

    assert_equal answer, normalize(answer, evidence_count: 0)
  end

  test "preserves a bracketed number printed literally in the evidence" do
    answer = "Conecte el borne [24]."

    assert_equal answer, normalize(answer, evidence_count: 1, evidence_text: "Borne [24]")
  end

  test "normalizes only non-literal markers in a mixed answer" do
    answer = "Conecte el borne [24]. Dato técnico [2]."

    assert_equal(
      "Conecte el borne [24]. Dato técnico [1].",
      normalize(answer, evidence_count: 1, evidence_text: "Borne [24]")
    )
  end

  test "flag off preserves the answer byte identical" do
    answer = "Primera [2][3]."
    ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = "false"

    assert_equal answer, normalize(answer, evidence_count: 1)
  end

  private

  def normalize(text, evidence_count:, evidence_text: "Contenido sin marcadores")
    Rag::CitationMarkerNormalizer.call(
      text,
      evidence_count: evidence_count,
      evidence_text: evidence_text
    )
  end
end
