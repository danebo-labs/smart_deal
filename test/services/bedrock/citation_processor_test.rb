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

  # span.end is INCLUSIVE (measured in production, docs/EJECUCION_PRE_DEMO_2026-09-10.md
  # Fase 1): it indexes the LAST character of the cited passage, so every fixture
  # below points at that character and the marker must land after it.

  test "inserts a marker after the inclusive end offset of the cited span" do
    answer = "EPC es un LED. B8 es un conector."
    span_end = answer.index("LED.") + "LED.".length - 1 # the "." closing the first sentence

    annotated = Bedrock::CitationProcessor.new.add_span_citations(
      answer, [ raw_citation(span_end: span_end) ]
    )

    assert_equal "EPC es un LED.[1] B8 es un conector.", annotated
  end

  test "numbers markers sequentially across citation groups and inserts in place" do
    answer = "Primera frase. Segunda frase."
    first_end = answer.index("frase.") + "frase.".length - 1
    second_end = answer.length - 1

    annotated = Bedrock::CitationProcessor.new.add_span_citations(
      answer,
      [ raw_citation(span_end: first_end), raw_citation(span_end: second_end) ]
    )

    assert_equal "Primera frase.[1] Segunda frase.[2]", annotated
  end

  test "an inclusive span ending on the last letter of a word keeps the word intact" do
    answer = "El carro llega al destino y abre puertas."
    span_end = answer.index("destino") + "destino".length - 1 # the final "o" of "destino"

    annotated = Bedrock::CitationProcessor.new.add_span_citations(
      answer, [ raw_citation(span_end: span_end) ]
    )

    assert_equal "El carro llega al destino[1] y abre puertas.", annotated
    assert_not_includes annotated, "destin[1]o"
  end

  test "advances to the next word boundary when the offset falls inside a word" do
    answer = "El contactor principal cierra."
    span_end = answer.index("principal") + 2 # mid-word: insertion would fall on the "n"

    annotated = Bedrock::CitationProcessor.new.add_span_citations(
      answer, [ raw_citation(span_end: span_end) ]
    )

    assert_equal "El contactor principal[1] cierra.", annotated
  end

  test "assigns one marker per retrieved reference in the group" do
    answer = "Dato compuesto."
    # span_end at answer.length is already out of range; +1 must stay clamped.
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

  # ===== tooltip_excerpt / content removal (Fase 3 §1 C1) =====

  test "build_numbered_references never includes a content key" do
    citations = [
      { content: "Contenido de prueba.", location: { key: "manual.pdf" }, metadata: {} }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert_not reference.key?(:content)
  end

  test "build_numbered_references exposes tooltip_excerpt truncated to 150 characters" do
    long_content = "x" * 300
    citations = [
      { content: long_content, location: { key: "manual.pdf" }, metadata: {} }
    ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert reference[:tooltip_excerpt].length <= 150
    assert_equal long_content.truncate(150), reference[:tooltip_excerpt]
  end

  test "build_numbered_references tooltip_excerpt is nil when content is blank" do
    citations = [ { content: "", location: {}, metadata: {} } ]

    reference = Bedrock::CitationProcessor.new.build_numbered_references(citations, "[1]").first

    assert_nil reference[:tooltip_excerpt]
  end

  # ===== strip_resolved_markers (Fase 3 §1 C2) =====

  test "strip_resolved_markers removes a marker that resolves to a real citation" do
    citations = [ { number: 1 } ]

    result = Bedrock::CitationProcessor.new.strip_resolved_markers("EPC en B8.[1]", citations)

    assert_equal "EPC en B8.", result
  end

  test "strip_resolved_markers preserves a bracketed number that is not a real citation (regression: literal [24] pin)" do
    citations = [ { number: 1 } ]
    answer = "El terminal [24] alimenta la bobina.[1]"

    result = Bedrock::CitationProcessor.new.strip_resolved_markers(answer, citations)

    assert_equal "El terminal [24] alimenta la bobina.", result
  end

  test "strip_resolved_markers preserves every marker when citations is empty" do
    result = Bedrock::CitationProcessor.new.strip_resolved_markers("Ver borne [24].", [])

    assert_equal "Ver borne [24].", result
  end

  test "transport_references removes deterministic content and derives a bounded tooltip" do
    references = [
      { number: 1, title: "Manual", content: "x" * 300, metadata: { "page_number" => 9 } }
    ]

    result = Bedrock::CitationProcessor.new.transport_references(references).first

    assert_not result.key?(:content)
    assert_equal(("x" * 300).truncate(150), result[:tooltip_excerpt])
    assert_equal({ "page_number" => 9 }, result[:metadata])
    assert references.first.key?(:content), "transport normalization must not mutate the internal citation"
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

  test "build_numbered_references collapses a repeated BL6 title and page" do
    fixture = JSON.parse(Rails.root.join("test/fixtures/real_gonzalo/chunks/bl6_citations.json").read)
    cited = fixture.fetch("citations")
    first = cited.find { |row| row["number"] == 1 }
    duplicate = cited.find { |row| row["number"] == 7 }
    assert_equal first["title"], duplicate["title"]
    assert_equal first["page"], duplicate["page"]
    assert_equal first["filename"], duplicate["filename"]

    citations = cited.map do |row|
      {
        content: "Er29",
        location: { key: row["filename"] },
        metadata: { "canonical_name" => row["title"].sub(/ — p\. \d+\z/, ""), "page_number" => row["page"] }
      }
    end
    answer = +"Er29 [1] y el mismo código [7]."

    references = Bedrock::CitationProcessor.new.build_numbered_references(citations, answer)

    assert_equal [ 1 ], references.pluck(:number)
    assert_equal "Codigos de Error BL6 — p. 4", references.first[:title]
    assert_equal "Er29 [1] y el mismo código [1].", answer
  end

  test "collapses consecutive markers that dedupe to the same BL6 page" do
    fixture = JSON.parse(Rails.root.join("test/fixtures/real_gonzalo/chunks/bl6_citations.json").read)
    cited = fixture.fetch("citations")
    pair = [ cited.find { |row| row["number"] == 1 }, cited.find { |row| row["number"] == 7 } ]
    assert_equal pair[0]["title"], pair[1]["title"]
    assert_equal pair[0]["page"], pair[1]["page"]
    assert_equal pair[0]["filename"], pair[1]["filename"]

    citations = pair.map do |row|
      {
        content: "Er29",
        location: { key: row["filename"] },
        metadata: { "canonical_name" => row["title"].sub(/ — p\. \d+\z/, ""), "page_number" => row["page"] }
      }
    end
    answer = +"Er29 [1][2]."

    references = Bedrock::CitationProcessor.new.build_numbered_references(citations, answer)

    assert_equal [ 1 ], references.pluck(:number)
    assert_equal "Codigos de Error BL6 — p. 4", references.first[:title]
    assert_equal "Er29 [1].", answer
  end

  test "keeps distinct fragments of the same document and page" do
    manual = {
      "canonical_name" => "Manual de puerta",
      "page_number" => 7,
      "original_source_uri" => "s3://bucket/manual.pdf",
      "document_id" => "doc-1"
    }
    opening = "La puerta queda abierta cuando el relé de apertura está activo."
    priority = "La señal de re-apertura tiene prioridad sobre la señal cerrar."
    citations = [
      fragment_citation("bulk_chunks/doc-1/chunk_p7_3.txt", opening, manual),
      fragment_citation("bulk_chunks/doc-1/chunk_p12_1.txt", "Página distinta.", manual.merge("page_number" => 12)),
      fragment_citation("bulk_chunks/doc-1/chunk_p4_1.txt", "Otra página.", manual.merge("page_number" => 4)),
      fragment_citation("bulk_chunks/doc-1/chunk_p7_2.txt", priority, manual)
    ]
    answer = +"Indicación de abierta [1]. «#{priority}» [4]."

    references = Bedrock::CitationProcessor.new.build_numbered_references(citations, answer)

    assert_equal [ 1, 4 ], references.pluck(:number)
    assert_equal "Manual de puerta — p. 7", references[0][:title]
    assert_equal references[0][:title], references[1][:title]
    assert_equal "chunk_p7_3.txt", references[0][:filename]
    assert_equal "chunk_p7_2.txt", references[1][:filename]
    assert_equal "bulk_chunks/doc-1/chunk_p7_3.txt", references[0][:location][:key]
    assert_equal "bulk_chunks/doc-1/chunk_p7_2.txt", references[1][:location][:key]
    assert_equal opening, references[0][:tooltip_excerpt]
    assert_equal priority, references[1][:tooltip_excerpt]
    assert_equal "Indicación de abierta [1]. «#{priority}» [4].", answer
    references.each { |reference| assert_not reference.key?(:content) }
  end

  test "does not merge different documents that share a title and page" do
    title = { "canonical_name" => "Manual de puerta", "page_number" => 7 }
    cabin = "El contacto de cabina cierra el circuito."
    landing = "El contacto de planta abre el circuito."
    citations = [
      fragment_citation(
        "chunk_p7_1.txt",
        cabin,
        title.merge("original_source_uri" => "s3://bucket/cabina.pdf", "document_id" => "cabina")
      ),
      fragment_citation(
        "chunk_p7_1.txt",
        landing,
        title.merge("original_source_uri" => "s3://bucket/planta.pdf", "document_id" => "planta")
      )
    ]
    answer = +"Cabina [1]. Planta [2]."

    references = Bedrock::CitationProcessor.new.build_numbered_references(citations, answer)

    assert_equal [ 1, 2 ], references.pluck(:number)
    assert_equal references[0][:title], references[1][:title]
    assert_equal references[0][:page], references[1][:page]
    assert_equal "chunk_p7_1.txt", references[0][:filename]
    assert_equal "chunk_p7_1.txt", references[1][:filename]
    assert_equal "s3://bucket/cabina.pdf", references[0][:metadata]["original_source_uri"]
    assert_equal "s3://bucket/planta.pdf", references[1][:metadata]["original_source_uri"]
    assert_equal cabin, references[0][:tooltip_excerpt]
    assert_equal landing, references[1][:tooltip_excerpt]
    assert_equal "Cabina [1]. Planta [2].", answer
    references.each { |reference| assert_not reference.key?(:content) }
  end

  test "keeps the captured T5 priority fragment after citation processing" do
    turn = t5_priority_turn
    answer = turn.rendered.dup
    references = Bedrock::CitationProcessor.new.build_numbered_references(
      turn.citations, answer, question: turn.question
    )
    marker = answer[/#{Regexp.escape(turn.sentence)}» \[(\d+)\]/, 1].to_i
    priority = references.find { |reference| reference[:number] == marker }
    photo_marker = answer[/«Fotocélula» \[(\d+)\]/, 1].to_i
    photo = references.find { |reference| reference[:number] == photo_marker }

    assert_equal turn.priority_source, turn.citations.size
    assert_equal turn.definition, turn.citations.last[:content]
    assert_nil turn.citations.last[:location]
    assert_equal turn.citations.first[:metadata]["x-amz-bedrock-kb-source-uri"],
      turn.citations.last[:metadata]["x-amz-bedrock-kb-source-uri"]
    assert_equal turn.rendered, answer
    assert_not_equal turn.published, answer
    assert_equal photo[:title], priority[:title]
    assert_equal photo[:page], priority[:page]
    assert_equal turn.priority_source, marker
    assert_equal turn.photo_source, photo_marker
    assert_includes priority[:metadata]["definition_provenance"], "chunk_p7_2.txt"
    assert_equal turn.definition.truncate(150), priority[:tooltip_excerpt]
    assert_includes turn.definition, turn.sentence
    assert_nil priority[:location]
    assert photo[:location][:key].end_with?("chunk_p7_3.txt")
    assert_equal turn.indicators.truncate(150), photo[:tooltip_excerpt]
    assert_includes turn.indicators, "Fotocélula"
    assert_not_includes turn.indicators, turn.sentence
    assert_not_equal priority[:tooltip_excerpt], photo[:tooltip_excerpt]
    if priority[:matched_excerpt]
      excerpt = priority[:matched_excerpt].delete_suffix("...").squish
      assert_includes turn.definition.squish, excerpt
      assert_not_includes turn.indicators, excerpt
    end
    references.each { |reference| assert_not reference.key?(:content) }
  end

  def fragment_citation(key, content, metadata)
    {
      content: content,
      location: { key: key, uri: "s3://bucket/#{key}" },
      metadata: metadata
    }
  end

  T5PriorityTurn = Struct.new(
    :citations, :rendered, :published, :question, :definition, :indicators,
    :sentence, :priority_source, :photo_source, keyword_init: true
  )

  def t5_priority_turn
    root = Rails.root.join(
      "test/fixtures/field_companion/vf5_t5_20261029/57908f55-0a29-48b4-96f5-d4bd095d55f0"
    )
    events = JSON.parse(root.join("capture.json").read).fetch("events")
    rendered = events.find { |event| event["kind"] == "companion_plan" }.fetch("rendered")
    published = events.find { |event| event["kind"] == "published_answer" }.fetch("answer")
    question = events.find { |event| event["kind"] == "user_message" }.fetch("sent")
    quotes = events.find { |event| event["kind"] == "companion_publication" }.fetch("quotes")
    sentence = "La señal de re-apertura tiene prioridad sobre la señal cerrar"
    priority_quote = quotes.find { |item| item["text"] == sentence }
    photo_quote = quotes.find { |item| item["text"] == "Fotocélula" }
    retrieved = events.find { |event|
      event["kind"] == "retrieval_results" && event["rows"]&.first&.dig("text").is_a?(Hash)
    }
    added = events.find { |event| event["kind"] == "companion_definitions" }.fetch("added").first
    prompt = root.join("bodies/b0006.txt").read
    definition = captured_source_text(prompt, priority_quote.fetch("source"))
    rows = retrieved.fetch("rows")
    indicators = root.join(rows.first.dig("text", "path")).read
    citations = rows.map { |row| captured_retrieval_citation(root, row) }
    citations << captured_definition_citation(citations.first, added, definition)

    T5PriorityTurn.new(
      citations: citations,
      rendered: rendered,
      published: published,
      question: question,
      definition: definition,
      indicators: indicators,
      sentence: sentence,
      priority_source: priority_quote.fetch("source"),
      photo_source: photo_quote.fetch("source")
    )
  end

  def captured_retrieval_citation(root, row)
    body = root.join(row.dig("text", "path")).read
    uri = row.fetch("uri")
    bucket, key = uri.delete_prefix("s3://").split("/", 2)
    {
      content: body,
      location: { bucket: bucket, key: key, uri: uri, type: "s3" },
      metadata: {
        "canonical_name" => row["document"],
        "page_number" => row["page"],
        "document_id" => row["document_id"],
        "original_source_uri" => body[/\[SOURCE_URI: (.+)\]/, 1],
        "x-amz-bedrock-kb-source-uri" => uri
      }
    }
  end

  def captured_definition_citation(source, added, definition)
    {
      content: definition,
      metadata: source[:metadata].merge(
        "page_number" => added["page"],
        "definition_of" => added["definition_of"],
        "definition_provenance" => [
          added["provenance"],
          "página #{added["page"]}",
          "sección #{added["section"]}",
          "encabezado #{added["heading"]}"
        ].join("; ")
      )
    }
  end

  def captured_source_text(prompt, source)
    capturing = false
    prompt.each_line.filter_map { |line|
      if (heading = line.match(/\A\[(\d+)\]/))
        capturing = heading[1].to_i == source
        next
      end
      next unless capturing

      line[/\AS#{source}\.\d+ \([^)]+\): (.+)\s*\z/, 1]
    }.join("\n")
  end
end
