# frozen_string_literal: true

require "test_helper"

class Rag::StructuredEvidenceRouteTest < ActiveSupport::TestCase
  MANUFACTURER_PATTERN = Regexp.union(
    %w[
      ALTIUS ORONA KONE OTIS SCHINDLER SOPREL THYSSENKRUPP THYSSEN
      CTA ELECMEGON ENIER TOKIBAT EDEL HIDRA SISTEL ALJO MR08 MICONIC SMART
    ].map { |name| /\b#{name}\b/i } + [ /CARLOS\s+SILVA/i ]
  ).freeze

  class FakeRagService
    attr_reader :calls

    def initialize(chunks)
      @chunks = chunks
      @calls = []
    end

    def retrieve_chunks(question, **kwargs)
      @calls << { question: question, **kwargs }
      {
        chunks: @chunks,
        retrieval_trace: {
          vector_search_configuration: {
            "number_of_results" => kwargs[:number_of_results]
          }
        }
      }
    end
  end

  class FakeGenerator
    attr_reader :calls

    def initialize(answer)
      @answer = answer
      @calls = []
    end

    def query(prompt, **kwargs)
      @calls << { prompt: prompt, **kwargs }
      @answer
    end
  end

  class FakeExpander
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def neighbor_chunk(divider_chunk:, target_page:)
      @calls << { divider_chunk: divider_chunk, target_page: target_page }
      target_page == 36 ? @result : nil
    end
  end

  setup do
    @original_flag = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    @original_partial_contract_flag =
      ENV.fetch("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil)
    @original_attribution_contract_flag =
      ENV.fetch("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED", nil)
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = "false"
    ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = "true"
    @account = accounts(:legacy)
    @source_uri = "s3://test-bucket/manual.pdf"
  end

  teardown do
    if @original_flag.nil?
      ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED")
    else
      ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = @original_flag
    end
    if @original_partial_contract_flag.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = @original_partial_contract_flag
    end
    if @original_attribution_contract_flag.nil?
      ENV.delete("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED")
    else
      ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = @original_attribution_contract_flag
    end
  end

  test "build requires web, a document pin, a structured non-safety non-exhaustive question, and the live flag" do
    assert build_route

    assert_nil build_route(output_channel: :whatsapp)
    assert_nil build_route(entity_s3_uris: [])
    assert_nil build_route(entity_sources: [ "image_upload" ])
    assert_nil build_route(question: "¿Qué indica esta señal?")
    assert_nil build_route(question: "Si falla el LED ABC12, ¿debo detener el trabajo?")
    assert_nil build_route(question: "Enumera todas las pruebas del LED ABC12")

    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
    assert_nil build_route
  end

  test "executes exactly one retrieve, replaces a divider through section_identity, and builds real citations" do
    divider = divider_chunk
    neighbor = neighbor_chunk
    rag_service = FakeRagService.new([ divider ])
    generator = FakeGenerator.new("ABC12 corresponde a la serie documentada. [1]")
    expander = FakeExpander.new(
      chunk: neighbor,
      mechanism: Rag::SectionNeighborExpander::MECHANISM_SECTION_IDENTITY
    )
    route = build_route(rag_service: rag_service, generator: generator, expander: expander)

    outcome = route.execute
    result = outcome.result

    assert_equal :answered, outcome.status
    assert_equal 1, rag_service.calls.size
    assert_equal RagRetrievalProfile::STRUCTURED_MAPPING_RESULTS,
                 rag_service.calls.first[:number_of_results]
    assert_equal true, rag_service.calls.first[:force_entity_filter]
    assert_equal [ 36 ], expander.calls.pluck(:target_page)
    assert_equal 1, generator.calls.size
    assert_includes generator.calls.first[:prompt], "Page: 36"
    assert_includes generator.calls.first[:prompt], "Chunk SHA256: neighbor-sha"
    assert_includes generator.calls.first[:prompt], "ABC12 | SERIE SEGURIDAD"
    assert_not_includes generator.calls.first[:prompt], "Página divisoria"
    assert_equal "structured_evidence_route", result[:generation_mode]
    assert_equal true, result[:model_invoked]
    assert_equal 1, result[:citations].size
    assert_equal 36, result[:citations].first[:page]
    assert_equal [ "neighbor-sha" ], result[:retrieved_chunk_sha256s]
    assert_equal [ :section_identity ],
                 result.dig(:retrieval_trace, :structured_route, :expansion_mechanisms)
    assert_equal 1, result.dig(:retrieval_trace, :structured_route, :generation_chunks)
    assert_equal :section_identity, result.dig(:diagnostics, :expansions, 0, :mechanism)
    generated_chunk = result.dig(:diagnostics, :generation_chunks, 0)
    assert_equal @source_uri, generated_chunk[:original_source_uri]
    assert_equal "s3://test-bucket/bedrock/divider.txt", generated_chunk[:bedrock_source_uri]
  end

  test "narrows widened recall to the labelled identifier and lexical sibling match" do
    target = {
      content: "## ABC12 - ELECTRICO\nLED ZX9 | SERIE PRINCIPAL",
      metadata: { "page_number" => 29, "section_identity" => "SECTION-A" },
      location_uri: "s3://test-bucket/chunks/target.txt",
      chunk_sha256: "target-sha",
      rank: 1
    }
    sibling = {
      content: "## ABC12 - HIDRAULICO\nLED ZX9 | SERIE PRINCIPAL",
      metadata: { "page_number" => 30, "section_identity" => "SECTION-A" },
      location_uri: "s3://test-bucket/chunks/sibling.txt",
      chunk_sha256: "sibling-sha",
      rank: 2
    }
    unrelated = {
      content: "## OTHER\nLED QP7 | SERIE SECUNDARIA",
      metadata: { "page_number" => 80, "section_identity" => "SECTION-B" },
      location_uri: "s3://test-bucket/chunks/unrelated.txt",
      chunk_sha256: "unrelated-sha",
      rank: 3
    }
    rag_service = FakeRagService.new([ target, sibling, unrelated ])
    generator = FakeGenerator.new("ZX9 identifica la serie principal. [1]")
    route = build_route(
      question: "En la placa ABC12 eléctrica, ¿qué LED identifica la serie principal?",
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    outcome = route.execute
    result = outcome.result
    prompt = generator.calls.first[:prompt]

    assert_equal :answered, outcome.status
    assert_includes prompt, "ABC12 - ELECTRICO"
    assert_not_includes prompt, "ABC12 - HIDRAULICO"
    assert_not_includes prompt, "LED QP7"
    assert_equal 1, result.dig(:retrieval_trace, :structured_route, :generation_chunks)
    assert_equal 3, result.dig(:retrieval_trace, :structured_route, :retrieved_chunks)
  end

  test "never accepts the interim adjacent-page mechanism on the live route" do
    rag_service = FakeRagService.new([ divider_chunk ])
    generator = FakeGenerator.new("No hay dato suficiente.")
    expander = FakeExpander.new(
      chunk: neighbor_chunk,
      mechanism: Rag::SectionNeighborExpander::MECHANISM_ADJACENT_PAGE
    )

    outcome = build_route(rag_service: rag_service, generator: generator, expander: expander).execute
    result = outcome.result

    assert_equal :abstained, outcome.status
    assert_equal [], result.dig(:diagnostics, :expansions)
    assert_includes generator.calls.first[:prompt], "Página divisoria"
    assert_not_includes generator.calls.first[:prompt], "ABC12 | SERIE SEGURIDAD"
  end

  test "a generation failure returns a terminal abstention without issuing a second retrieve" do
    rag_service = FakeRagService.new([ neighbor_chunk ])
    generator = FakeGenerator.new(nil)

    outcome = build_route(
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :abstained, outcome.status
    assert_equal I18n.t("rag.data_not_available", locale: :es), outcome.result[:answer]
    assert_empty outcome.result[:citations]
    assert_equal 1, rag_service.calls.size
    assert_equal 1, generator.calls.size
  end

  test "a retrieve failure is unavailable so the existing cascade may run" do
    calls = 0
    rag_service = Object.new
    rag_service.define_singleton_method(:retrieve_chunks) do |*_args, **_kwargs|
      calls += 1
      raise BedrockRagService::BedrockServiceError, "temporary retrieve failure"
    end

    outcome = build_route(
      rag_service: rag_service,
      generator: FakeGenerator.new("must not run"),
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :unavailable, outcome.status
    assert_nil outcome.result
    assert_equal 1, calls
  end

  test "an empty retrieved set is a terminal abstention without generation" do
    rag_service = FakeRagService.new([])
    generator = FakeGenerator.new("must not run")

    outcome = build_route(
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :abstained, outcome.status
    assert_empty outcome.result[:citations]
    assert_empty generator.calls
    assert_equal 1, rag_service.calls.size
  end

  test "bare identifiers select a rank-seven target instead of the first three chunks" do
    chunks = Array.new(12) { |index| synthetic_chunk("Contenido general #{index + 1}", rank: index + 1) }
    target = synthetic_chunk(
      "ZZ9000 V1 | CONECTORES XA1 Y XB2",
      rank: 7,
      sha: "target-rank-seven"
    )
    chunks[6] = target
    route = route_for_selection(
      "En ZZ9000 V1, ¿qué conectores documenta el encabezado de la placa?"
    )

    selected = route.send(:select_generation_chunks, chunks)

    assert_equal [ "target-rank-seven" ], selected.pluck(:chunk_sha256)
    assert_operator selected.size, :<=, Rag::StructuredEvidenceRoute::MAX_GENERATION_CHUNKS
  end

  test "labelled identifiers retain priority over bare identifiers" do
    labelled = synthetic_chunk("LED ZX9 | SERIE PRINCIPAL", rank: 2, sha: "labelled")
    bare_only = synthetic_chunk("ABC12 | OTRA INFORMACION", rank: 1, sha: "bare")
    route = route_for_selection(
      "En ABC12, ¿qué LED ZX9 identifica la serie principal?"
    )

    selected = route.send(:select_generation_chunks, [ bare_only, labelled ])

    assert_equal [ "labelled" ], selected.pluck(:chunk_sha256)
    assert_operator selected.size, :<=, Rag::StructuredEvidenceRoute::MAX_GENERATION_CHUNKS
  end

  test "bare multi-target coverage selects the two chunks that cover three identifiers" do
    first = synthetic_chunk("A10 y B20 documentados", rank: 4, sha: "first-targets")
    second = synthetic_chunk("C30 documentado", rank: 6, sha: "second-target")
    distractors = Array.new(5) { |index| synthetic_chunk("General #{index}", rank: index + 1) }
    route = route_for_selection(
      "¿Qué LEDs documenta el manual y qué significan A10, B20 y C30?"
    )

    selected = route.send(:select_generation_chunks, distractors + [ first, second ])

    assert_equal %w[first-targets second-target], selected.pluck(:chunk_sha256)
    assert_operator selected.size, :<=, Rag::StructuredEvidenceRoute::MAX_GENERATION_CHUNKS
  end

  test "generation selection never exceeds five chunks" do
    identifiers = %w[A10 B20 C30 D40 E50 F60 G70 H80]
    chunks = identifiers.each_with_index.map do |identifier, index|
      synthetic_chunk("#{identifier} documentado", rank: index + 1, sha: "target-#{identifier}")
    end
    route = route_for_selection(
      "¿Qué LEDs documenta el manual y qué significan #{identifiers.join(", ")}?"
    )

    selected = route.send(:select_generation_chunks, chunks)

    assert_equal Rag::StructuredEvidenceRoute::MAX_GENERATION_CHUNKS, selected.size
  end

  test "selection without identifiers keeps the first three chunks" do
    chunks = Array.new(6) { |index| synthetic_chunk("Contenido #{index}", rank: index + 1, sha: "chunk-#{index}") }
    route = route_for_selection("¿Qué información documenta el manual?")

    selected = route.send(:select_generation_chunks, chunks)

    assert_equal %w[chunk-0 chunk-1 chunk-2], selected.pluck(:chunk_sha256)
    assert_operator selected.size, :<=, Rag::StructuredEvidenceRoute::MAX_GENERATION_CHUNKS
  end

  test "a sibling variant cannot beat the chunk containing the requested variant" do
    sibling = synthetic_chunk("QQ7 V1 | CONECTORES XA1", rank: 1, sha: "sibling-v1")
    target = synthetic_chunk("QQ7 V2 | CONECTORES XB2", rank: 7, sha: "target-v2")
    route = route_for_selection(
      "En QQ7 V2, ¿qué conectores documenta el encabezado?"
    )

    selected = route.send(:select_generation_chunks, [ sibling, target ])

    assert_equal [ "target-v2" ], selected.pluck(:chunk_sha256)
    assert_not route.send(:identifier_present?, sibling[:content], "V2")
    assert_operator selected.size, :<=, Rag::StructuredEvidenceRoute::MAX_GENERATION_CHUNKS
  end

  test "an unknown model absent from evidence ends in safe abstention" do
    chunks = Array.new(3) { |index| synthetic_chunk("Documento general #{index}", rank: index + 1) }
    rag_service = FakeRagService.new(chunks)
    generator = FakeGenerator.new("DATA_NOT_AVAILABLE")

    outcome = build_route(
      question: "En la placa ZZ9000, ¿qué LED indica la serie de puertas?",
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :abstained, outcome.status
    assert_equal I18n.t("rag.data_not_available", locale: :es), outcome.result[:answer]
    assert_empty outcome.result[:citations]
  end

  test "a partially documented multi-objective answer preserves the documented fact and abstains from the rest" do
    chunk = synthetic_chunk(
      "QQ7 V1 | CONECTOR XA1. El documento no declara par de apriete.",
      rank: 1,
      sha: "partial"
    )
    rag_service = FakeRagService.new([ chunk ])
    generator = FakeGenerator.new(
      "El conector documentado es \"XA1\". [1]\nDATA_NOT_AVAILABLE para el par de apriete."
    )

    outcome = build_route(
      question: "En QQ7 V1, ¿qué conectores documenta el encabezado y cuál es el par de apriete?",
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :answered, outcome.status
    assert_includes outcome.result[:answer], "XA1"
    assert_includes outcome.result[:answer], I18n.t("rag.data_not_available", locale: :es)
    assert_equal 1, outcome.result[:citations].size
  end

  test "a partially-abstaining answer that still cites the documented part passes the citation gate" do
    chunk = synthetic_chunk(
      "LED DL91 | SERIE ZETA HUECO",
      rank: 1,
      sha: "partial-state"
    )
    raw_answer = "DL91 corresponde a \"SERIE ZETA HUECO\" [1].\n\n" \
      "El documento no especifica la condición normal."
    rag_service = FakeRagService.new([ chunk ])

    with_partial_contract("true") do
      outcome = build_route(
        question: "En ZR7-K1, ¿qué LED DL91 corresponde a la condición normal?",
        rag_service: rag_service,
        generator: FakeGenerator.new(raw_answer),
        expander: FakeExpander.new(nil)
      ).execute

      assert_equal :answered, outcome.status
      assert_includes outcome.result[:answer], "SERIE ZETA HUECO"
      assert_includes outcome.result[:answer], I18n.t("rag.data_not_available", locale: :es)
      assert_includes outcome.result[:answer], I18n.t("rag.requires_field_verification", locale: :es)
      assert_equal [ 1 ], outcome.result[:answer].scan(/\[(\d+)\]/).flatten.map(&:to_i)
      assert_equal [ 1 ], outcome.result[:citations].pluck(:number)
      assert_equal 1, rag_service.calls.size
    end
  end

  test "an appended absence paragraph changes neither markers nor citations" do
    chunk = synthetic_chunk("LED DL91 | SERIE ZETA HUECO", rank: 1, sha: "citation-invariant")
    raw_answer = "DL91 corresponde a \"SERIE ZETA HUECO\" [1].\n\n" \
      "#{"Detalle documentado sin cambio. " * 10}" \
      "El documento no especifica la condición normal."
    off_service = FakeRagService.new([ chunk ])
    on_service = FakeRagService.new([ chunk ])

    off = with_partial_contract("false") do
      build_route(
        question: "En ZR7-K1, ¿qué LED DL91 corresponde a la condición normal?",
        rag_service: off_service,
        generator: FakeGenerator.new(raw_answer),
        expander: FakeExpander.new(nil)
      ).execute.result
    end
    on = with_partial_contract("true") do
      build_route(
        question: "En ZR7-K1, ¿qué LED DL91 corresponde a la condición normal?",
        rag_service: on_service,
        generator: FakeGenerator.new(raw_answer),
        expander: FakeExpander.new(nil)
      ).execute.result
    end

    assert_equal raw_answer, off[:answer]
    assert_equal off[:answer].scan(/\[(\d+)\]/), on[:answer].scan(/\[(\d+)\]/)
    assert_equal off[:citations], on[:citations]
    assert_equal 1, off_service.calls.size
    assert_equal off_service.calls.size, on_service.calls.size
  end

  test "the generated prompt scopes language and requires verbatim documented values" do
    rag_service = FakeRagService.new([ neighbor_chunk ])
    generator = FakeGenerator.new("\"SERIE CAB. EXT. CERRADA\" [1]")

    outcome = build_route(
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    ).execute
    prompt = generator.calls.first[:prompt]

    assert_equal :answered, outcome.status
    assert_includes prompt, "Write the explanatory prose in Spanish"
    assert_includes prompt, "Never translate or rewrite a value reproduced verbatim"
    assert_match(/reproduce that\s+string exactly as printed/, prompt)
    assert_includes prompt, "same characters, casing, abbreviations, internal"
    assert_no_match MANUFACTURER_PATTERN, prompt
    assert_no_match(/reproduce that\s+string exactly as printed/,
      BedrockRagService.load_generation_prompt_template)
  end

  test "answer safety preserves a quoted uppercase label with internal punctuation" do
    label = '"SERIE CAB. EXT. CERRADA"'
    answer = "#{label} [1]"
    processed = Rag::AnswerSafetyProcessor.new(locale: :es).call(
      answer,
      evidence: [ { content: label } ],
      require_cited_evidence: true
    )

    assert_equal answer, processed
  end

  test "out-of-range citation markers remain invalid with multiple evidence chunks" do
    chunks = [
      synthetic_chunk("LED ABC12 | SERIE PRINCIPAL", rank: 1, sha: "abc12"),
      synthetic_chunk("LED DEF34 | SERIE SECUNDARIA", rank: 2, sha: "def34")
    ]
    rag_service = FakeRagService.new(chunks)
    generator = FakeGenerator.new("Afirmación técnica [3]")

    outcome = build_route(
      question: "¿Qué indican los LEDs ABC12 y DEF34?",
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :abstained, outcome.status
    assert_empty outcome.result[:citations]
    assert_equal :citation_failure, outcome.result.dig(:diagnostics, :outcome_reason)
  end

  test "single-context assertion markers normalize to the sole evidence block" do
    rag_service = FakeRagService.new([ neighbor_chunk ])
    raw_answer = "ABC12 corresponde a la serie [1]. Otra afirmación [2]. Tercera [3]."

    outcome = build_route(
      rag_service: rag_service,
      generator: FakeGenerator.new(raw_answer),
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :answered, outcome.status
    assert_equal 1, outcome.result[:citations].size
    assert_equal raw_answer, outcome.result.dig(:diagnostics, :raw_answer)
    assert_equal(
      "ABC12 corresponde a la serie [1]. Otra afirmación [1]. Tercera [1].",
      outcome.result.dig(:diagnostics, :normalized_answer)
    )
    assert_equal 1, rag_service.calls.size
    assert_equal 1, outcome.result.dig(:retrieval_trace, :structured_route, :generation_chunks)
  end

  test "literal bracketed number in sole evidence remains a citation failure" do
    chunk = synthetic_chunk("Conecte el borne [24]", rank: 1, sha: "literal-24")
    rag_service = FakeRagService.new([ chunk ])

    outcome = build_route(
      question: "En ABC12, ¿qué borne documenta el esquema?",
      rag_service: rag_service,
      generator: FakeGenerator.new("Conecte el borne [24]"),
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :abstained, outcome.status
    assert_empty outcome.result[:citations]
    assert_equal :citation_failure, outcome.result.dig(:diagnostics, :outcome_reason)
  end

  test "dropping every attributed marker abstains with attribution failure" do
    chunks = [
      synthetic_chunk("LED ABC12 | SERIE PRINCIPAL", rank: 1, sha: "thyssen").tap do |chunk|
        chunk[:metadata]["section_identity"] = "THYSSEN"
      end,
      synthetic_chunk("LED DEF34 | SERIE SECUNDARIA", rank: 2, sha: "otis").tap do |chunk|
        chunk[:metadata]["section_identity"] = "OTIS"
      end
    ]
    rag_service = FakeRagService.new(chunks)

    outcome = build_route(
      question: "En THYSSEN, ¿qué indican los LEDs ABC12 y DEF34?",
      rag_service: rag_service,
      generator: FakeGenerator.new("DEF34 corresponde a la serie secundaria [2]"),
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :abstained, outcome.status
    assert_empty outcome.result[:citations]
    assert_equal :attribution_failure, outcome.result.dig(:diagnostics, :outcome_reason)
    assert_equal 1, rag_service.calls.size
    assert_equal 2, outcome.result.dig(:retrieval_trace, :structured_route, :generation_chunks)
  end

  test "the structured turn does not create a BedrockQuery row for pure retrieval" do
    rag_service = FakeRagService.new([ neighbor_chunk ])
    generator = FakeGenerator.new("ABC12 corresponde a la serie documentada. [1]")

    assert_no_difference("BedrockQuery.count") do
      outcome = build_route(
        rag_service: rag_service,
        generator: generator,
        expander: FakeExpander.new(nil)
      ).execute
      assert_equal :answered, outcome.status
    end
  end

  private

  def with_partial_contract(value)
    previous = ENV.fetch("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil)
    ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = value
    yield
  ensure
    if previous.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = previous
    end
  end

  def build_route(question: "¿Qué indica el LED ABC12?", entity_s3_uris: [ @source_uri ],
                  entity_sources: [ "document" ], output_channel: :web, rag_service: nil,
                  generator: nil, expander: nil)
    Rag::StructuredEvidenceRoute.build(
      question: question,
      account: @account,
      entity_s3_uris: entity_s3_uris,
      entity_sources: entity_sources,
      force_entity_filter: true,
      response_locale: :es,
      output_channel: output_channel,
      rag_service: rag_service,
      generator: generator,
      expander: expander
    )
  end

  def route_for_selection(question)
    Rag::StructuredEvidenceRoute.new(
      question: question,
      account: @account,
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: FakeRagService.new([]),
      generator: FakeGenerator.new(nil),
      expander: FakeExpander.new(nil)
    )
  end

  def synthetic_chunk(content, rank:, sha: nil)
    {
      content: content,
      metadata: {
        "canonical_name" => "Manual sintético",
        "original_source_uri" => @source_uri,
        "page_number" => rank
      },
      location_uri: "s3://test-bucket/chunks/chunk_#{rank}.txt",
      chunk_sha256: sha || "sha-#{rank}-#{Digest::SHA256.hexdigest(content).first(8)}",
      rank: rank
    }
  end

  def divider_chunk
    {
      content: "Página divisoria",
      metadata: {
        "canonical_name" => "Manual",
        "original_source_uri" => @source_uri,
        "page_number" => 35,
        "section_identity" => "SECTION-A"
      },
      original_source_uri: @source_uri,
      bedrock_source_uri: "s3://test-bucket/bedrock/divider.txt",
      location_uri: "s3://test-bucket/chunks/chunk_33.txt",
      chunk_sha256: "divider-sha",
      rank: 1
    }
  end

  def neighbor_chunk
    {
      content: "LED ABC12 | SERIE SEGURIDAD",
      metadata: {
        "canonical_name" => "Manual",
        "original_source_uri" => @source_uri,
        "page_number" => 36,
        "section_identity" => "SECTION-A"
      },
      location_uri: "s3://test-bucket/chunks/chunk_34.txt",
      chunk_sha256: "neighbor-sha",
      rank: 1
    }
  end
end
