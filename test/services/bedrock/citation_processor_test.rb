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

  # ===== canonical_name priority (gap #6 / V3) =====

  test "build_numbered_references prefers canonical_name over title" do
    citations = [
      {
        content: "Contenido",
        location: { key: "bulk_chunks/manual/chunk_67.txt" },
        metadata: { "canonical_name" => "Manual Plataforma Tijera", "title" => "chunk_67.txt" }
      }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert_equal "Manual Plataforma Tijera", reference[:title]
  end

  test "build_numbered_references falls back to title when canonical_name is blank" do
    citations = [
      {
        content: "Contenido",
        location: { key: "manual.pdf" },
        metadata: { "canonical_name" => "", "title" => "SEGURIDADES" }
      }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert_equal "SEGURIDADES", reference[:title]
  end

  test "build_numbered_references falls back to filename when neither canonical_name nor title is present" do
    citations = [
      {
        content: "Contenido",
        location: { key: "bulk_chunks/manual/chunk_67.txt" },
        metadata: {}
      }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert_equal "chunk_67.txt", reference[:title]
  end

  # ===== matched_excerpt =====

  test "matched_excerpt picks the sentence with the most token overlap" do
    citations = [
      {
        content: "El botón B34 muestra la potencia del circuito X. La tensión nominal es 24V. " \
                  "El relé K3 controla la puerta principal.",
        location: { key: "manual.pdf" },
        metadata: {}
      }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿qué muestra el botón B34?"
    ).first

    assert_equal "El botón B34 muestra la potencia del circuito X.", reference[:matched_excerpt]
  end

  test "matched_excerpt is nil when no sentence reaches the overlap threshold" do
    citations = [
      { content: "El relé K3 controla la puerta principal.", location: {}, metadata: {} }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿cuál es la presión hidráulica máxima?"
    ).first

    assert_nil reference[:matched_excerpt]
  end

  test "matched_excerpt is nil when question is not given (backward compatibility)" do
    citations = [
      { content: "El botón B34 muestra la potencia del circuito X.", location: {}, metadata: {} }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert_nil reference[:matched_excerpt]
  end

  test "matched_excerpt truncates to 140 characters" do
    long_sentence = "El procedimiento de mantenimiento preventivo del circuito hidráulico requiere " \
                    "verificar la presión, el nivel de aceite, la temperatura del motor y el estado " \
                    "general de todas las mangueras y conexiones antes de continuar."
    citations = [ { content: long_sentence, location: {}, metadata: {} } ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿cuál es el procedimiento de mantenimiento preventivo?"
    ).first

    assert reference[:matched_excerpt].length <= 140
  end

  test "matched_excerpt ignores accents and capitalization" do
    citations = [
      { content: "La PRESIÓN máxima del sistema es de 3000 PSI.", location: {}, metadata: {} }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "presion maxima del sistema"
    ).first

    assert_equal "La PRESIÓN máxima del sistema es de 3000 PSI.", reference[:matched_excerpt]
  end

  test "matched_excerpt discards the chunk identity header" do
    content = "[DOCUMENT: manual.pdf]\n[SOURCE_URI: s3://bucket/manual.pdf]\n[SEARCH_ALIASES: HPM-400]\n\n" \
              "El botón B34 muestra la potencia del circuito X."
    citations = [ { content: content, location: {}, metadata: {} } ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿qué muestra el botón B34?"
    ).first

    assert_equal "El botón B34 muestra la potencia del circuito X.", reference[:matched_excerpt]
    assert_not_includes reference[:matched_excerpt], "DOCUMENT:"
  end

  test "matched_excerpt still returns a useful sentence for a chunk that starts with the S0 identification table" do
    content = "# S0 — DOCUMENT IDENTIFICATION\n" \
              "| Field | Value |\n" \
              "|-|-|\n" \
              "| ORIGINAL_FILE_NAME | PIPELINE_INJECTED |\n" \
              "| NORMALIZED_FILE_NAME | PIPELINE_INJECTED |\n" \
              "| TECHNICAL_ID | Orona Arc Arca I |\n" \
              "| REGIONAL_NORMATIVE | EN 81-20 |\n" \
              "| IMAGE_QUALITY | CLEAR |\n" \
              "| CONFIDENCE | HIGH |\n" \
              "| ERA | TRANSITIONAL |\n\n" \
              "El contactor K3 controla el motor principal de tracción."
    citations = [ { content: content, location: {}, metadata: {} } ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿qué controla el contactor K3?"
    ).first

    assert_equal "El contactor K3 controla el motor principal de tracción.", reference[:matched_excerpt]
    assert_not_includes reference[:matched_excerpt], "PIPELINE_INJECTED"
    assert_not_includes reference[:matched_excerpt], "S0"
  end

  test "matched_excerpt discards a bold DOCUMENT_ALIASES header and its alias bullets" do
    content = "**DOCUMENT_ALIASES:**\n- 952408286\n- arca\n- basic arca\n\n" \
              "El relé K3 controla la puerta principal."
    citations = [ { content: content, location: {}, metadata: {} } ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿qué controla el relé K3?"
    ).first

    assert_equal "El relé K3 controla la puerta principal.", reference[:matched_excerpt]
  end

  test "matched_excerpt strips a flattened PROD Title-Case metadata prefix" do
    content = "**Document:** ALJO Control Level 1B Altius **Section:** S7 — DIAGRAM **Page:** 3 " \
              "Esta página muestra el diagrama de control del nivel B8."
    citations = [ { content: content, location: {}, metadata: {} } ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿qué muestra esta página del diagrama?"
    ).first

    assert_equal "Esta página muestra el diagrama de control del nivel B8.", reference[:matched_excerpt]
    assert_not_includes reference[:matched_excerpt], "**Document:**"
    assert_not_includes reference[:matched_excerpt], "**Section:**"
    assert_not_includes reference[:matched_excerpt], "**Page:**"
  end

  test "matched_excerpt strips a colon-inside-bold Document header" do
    content = "**Document: Manual Plataforma Tijera**\nEl botón B34 muestra la potencia del circuito X."
    citations = [ { content: content, location: {}, metadata: {} } ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿qué muestra el botón B34?"
    ).first

    assert_equal "El botón B34 muestra la potencia del circuito X.", reference[:matched_excerpt]
  end

  test "matched_excerpt is nil when the chunk is only metadata" do
    content = "**Document:** ALJO Control Level 1B Altius **Section:** S7 — DIAGRAM **Page:** 3"
    citations = [ { content: content, location: {}, metadata: {} } ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿qué muestra esta página del diagrama?"
    ).first

    assert_nil reference[:matched_excerpt]
  end

  test "matched_excerpt does not strip the word Document in plain prose" do
    content = "Este Document describe el procedimiento de mantenimiento del circuito hidráulico."
    citations = [ { content: content, location: {}, metadata: {} } ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "[1]", question: "¿qué describe el documento de mantenimiento?"
    ).first

    assert_equal content, reference[:matched_excerpt]
  end

  test "matched_excerpt does not alter filename, title, or page" do
    citations = [
      {
        content: "EPC se conecta en B8.",
        location: { key: "bulk_chunks/manual/chunk_p11_1.txt", uri: "s3://bucket/chunk.txt" },
        metadata: { "title" => "SEGURIDADES", "page_number" => 11 }
      }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(
      citations, "Respuesta [1]", question: "¿dónde se conecta el EPC?"
    ).first

    assert_equal 11, reference[:page]
    assert_equal "SEGURIDADES — p. 11", reference[:title]
    assert_equal "chunk_p11_1.txt", reference[:filename]
  end
end
