# frozen_string_literal: true

require "test_helper"

class Bedrock::CitationProcessorTest < ActiveSupport::TestCase
  test "adds the indexed page number to a rendered citation" do
    citations = [
      {
        content: "EPC se conecta en B8.",
        location: { key: "bulk_chunks/manual/chunk_p11_1.txt", uri: "s3://bucket/chunk.txt" },
        metadata: { "title" => "SEGURIDADES", "page_number" => 11 }
      }
    ]

    references = Bedrock::CitationProcessor.new.build_numbered_references(citations, "Respuesta [1]")

    assert_equal 11, references.first[:page]
    assert_equal "SEGURIDADES — p. 11", references.first[:title]
  end

  test "accepts the native Bedrock page metadata key" do
    citations = [
      {
        content: "Contenido",
        location: { key: "manual.pdf", uri: "s3://bucket/manual.pdf" },
        metadata: { "x-amz-bedrock-kb-document-page-number" => "25" }
      }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert_equal 25, reference[:page]
    assert_equal "manual.pdf — p. 25", reference[:title]
  end

  test "extracts a page from legacy chunk content when metadata is absent" do
    citations = [
      {
        content: "**Document:** Manual\n**Page:** 31\nContenido",
        location: { key: "bulk_chunks/manual/chunk.txt", uri: "s3://bucket/chunk.txt" },
        metadata: {}
      }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert_equal 31, reference[:page]
    assert_equal "chunk.txt — p. 31", reference[:title]
  end

  test "extracts a page from a legacy chunk key as final fallback" do
    citations = [
      {
        content: "Contenido sin página",
        location: {
          key: "bulk_chunks/manual/chunk_p40_1.txt",
          uri: "s3://bucket/bulk_chunks/manual/chunk_p40_1.txt"
        },
        metadata: {}
      }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert_equal 40, reference[:page]
  end

  # ===== F2 — real span-based attribution =====

  def raw_citation(span_end:, references: 1)
    ::OpenStruct.new(
      generated_response_part: ::OpenStruct.new(
        text_response_part: ::OpenStruct.new(
          span: ::OpenStruct.new(start: 0, end: span_end)
        )
      ),
      retrieved_references: Array.new(references) { ::OpenStruct.new(content: ::OpenStruct.new(text: "chunk")) }
    )
  end

  test "inserts a marker at the real end offset of the cited span" do
    answer = "EPC es un LED. B8 es un conector."
    span_end = answer.index("LED.") + "LED.".length # end of the first sentence

    annotated = Bedrock::CitationProcessor.new.add_span_citations(
      answer, [ raw_citation(span_end: span_end) ]
    )

    assert_equal "EPC es un LED.[1] B8 es un conector.", annotated
  end

  test "numbers markers sequentially across citation groups and inserts in place" do
    answer = "Primera frase. Segunda frase."
    first_end = answer.index("frase.") + "frase.".length
    second_end = answer.length

    annotated = Bedrock::CitationProcessor.new.add_span_citations(
      answer,
      [ raw_citation(span_end: first_end), raw_citation(span_end: second_end) ]
    )

    assert_equal "Primera frase.[1] Segunda frase.[2]", annotated
  end

  test "assigns one marker per retrieved reference in the group" do
    answer = "Dato compuesto."
    annotated = Bedrock::CitationProcessor.new.add_span_citations(
      answer, [ raw_citation(span_end: answer.length, references: 2) ]
    )

    assert_equal "Dato compuesto.[1][2]", annotated
  end

  test "appends the marker when the span offset is missing" do
    citation = ::OpenStruct.new(
      retrieved_references: [ ::OpenStruct.new(content: ::OpenStruct.new(text: "chunk")) ]
    )

    annotated = Bedrock::CitationProcessor.new.add_span_citations("Sin span disponible.", [ citation ])

    assert_equal "Sin span disponible.[1]", annotated
  end

  test "returns the answer untouched when there are no citations" do
    assert_equal "Respuesta.", Bedrock::CitationProcessor.new.add_span_citations("Respuesta.", [])
  end
end
