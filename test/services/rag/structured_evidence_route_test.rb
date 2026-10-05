# frozen_string_literal: true

require "test_helper"
require "stringio"

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
    @original_gs_flag = ENV.fetch("RAG_GROUNDED_SYNTHESIS_ENABLED", nil)
    ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
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
    if @original_gs_flag.nil?
      ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
    else
      ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = @original_gs_flag
    end
  end

  test "build requires web, a document pin, a structured non-safety non-exhaustive question, and the live flag" do
    assert build_route

    assert_nil build_route(output_channel: :whatsapp)
    assert_nil build_route(entity_s3_uris: [])
    assert_nil build_route(entity_sources: [ "image_upload" ])
    assert_nil build_route(question: "¿Dónde está el cuadro de maniobra?")
    assert_nil build_route(question: "Si el freno falla, ¿debo detener el trabajo?")
    assert_nil build_route(question: "Enumera todas las pruebas del LED ABC12")
    assert build_route(question: "Si falla el LED ABC12, ¿debo detener el trabajo?")
    assert_nil build_route(
      question: "Si falla el LED ABC12, ¿debo detener el trabajo?",
      entity_s3_uris: [ @source_uri, "s3://test-bucket/other.pdf" ]
    )
    assert build_route(question: "¿A qué borne corresponde Seguridad OUT?")

    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
    assert_nil build_route
  end

  test "build admits a pinned exact designator lookup" do
    assert build_route(question: "¿Qué es K1?")
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

  test "answered outcome emits [PILOT_AUDIT] lines with full question/answer and citation-derived document/page" do
    rag_service = FakeRagService.new([ neighbor_chunk ])
    generator = FakeGenerator.new("ABC12 corresponde a la serie documentada. [1]")
    route = build_route(rag_service: rag_service, generator: generator)

    output = with_audit_capture("true") { route.execute }
    lines = output.lines.grep(/\[PILOT_AUDIT\]/)

    assert_equal 2, lines.size
    interaction = parse_audit(lines.first)
    assert_equal "interaction", interaction["type"]
    assert_equal "¿Qué indica el LED ABC12?", interaction["question"]
    assert_equal "ABC12 corresponde a la serie documentada. [1]", interaction["answer"]
    assert_equal 1, interaction["citations"].size
    assert_equal 36, interaction["citations"].first["page"]

    chunk = parse_audit(lines.second)
    assert_equal "chunk", chunk["type"]
    assert_equal "Manual", chunk["document"]
    assert_equal 36, chunk["page"]
    assert_equal "LED ABC12 | SERIE SEGURIDAD", chunk["text"]
    assert_equal false, chunk["truncated"]
  end

  test "disabled gate emits no [PILOT_AUDIT] lines for the structured route" do
    route = build_route(
      rag_service: FakeRagService.new([ neighbor_chunk ]),
      generator: FakeGenerator.new("ABC12 corresponde a la serie documentada. [1]")
    )

    output = with_audit_capture(nil) { route.execute }

    assert_not_includes output, "[PILOT_AUDIT]"
  end

  # Closes the production gap found while gating the 2026-08-05 export: an
  # abstained structured-route interaction with no evidence still needs its
  # question captured, so the value dossier never shows a blank "Pregunta: n/a"
  # for a question the technician actually asked.
  test "abstained outcome still audits the question even with no citations or chunks" do
    route = build_route(rag_service: FakeRagService.new([]), generator: FakeGenerator.new(""))

    output = with_audit_capture("true") { route.execute }
    lines = output.lines.grep(/\[PILOT_AUDIT\]/)

    assert_equal 1, lines.size
    interaction = parse_audit(lines.first)
    assert_equal "¿Qué indica el LED ABC12?", interaction["question"]
    assert_empty interaction["citations"]
  end

  # Pins the Fase 2 extract method as an equivalence, not a rewrite: a caller
  # that already spent the turn's Retrieve (Rag::AmbiguousModelResponder) must
  # get exactly what #execute would have produced for the same evidence.
  test "execute is retrieve plus complete_from_retrieval over the same evidence" do
    answer = "ABC12 corresponde a la serie documentada. [1]"
    whole = build_route(
      rag_service: FakeRagService.new([ neighbor_chunk ]),
      generator: FakeGenerator.new(answer)
    ).execute

    split_service = FakeRagService.new([ neighbor_chunk ])
    split_route = build_route(rag_service: split_service, generator: FakeGenerator.new(answer))
    retrieval = split_service.retrieve_chunks(
      "¿Qué indica el LED ABC12?",
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      number_of_results: RagRetrievalProfile::STRUCTURED_MAPPING_RESULTS,
      account_id: @account.id
    )
    split = split_route.complete_from_retrieval(retrieval, retrieval_ms: 0)

    assert_equal :answered, whole.status
    assert_equal whole.status, split.status
    assert_equal comparable_result(whole.result), comparable_result(split.result)
  end

  test "complete_from_retrieval abstains instead of reporting the retrieve as unspent" do
    route = build_route(
      rag_service: FakeRagService.new([]),
      generator: FakeGenerator.new(nil)
    )

    outcome = route.complete_from_retrieval({ chunks: [], retrieval_trace: {} }, retrieval_ms: 0)

    assert_equal :abstained, outcome.status
    assert_equal :empty_evidence, outcome.result.dig(:diagnostics, :outcome_reason)
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
    assert_equal 2, rag_service.calls.size
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, rag_service.calls.last[:number_of_results]
  end

  test "exact designator lookup compacts K1 conflicts without using alias lines" do
    chunks = [
      designator_chunk(1, "[SEARCH_ALIASES: K1, 24VAC SUBE]\nH14 aparece en el listado junto con H13\n- K1: Contactor/relé — bobina A1-A2. Contactos: 21, 24 (principal). Involucrado en circuito SUBE/BAJA."),
      designator_chunk(2, "ACTION: K1 Contactor 24VAC SUBE\n| K1 | Contactor 24VAC SUBE |"),
      designator_chunk(3, "| K1 | Contactor/relé | 24VDC (impreso en plano) |"),
      designator_chunk(4, "- K1: Contactor principal (asociado a Q2)")
    ]
    selected = route_for_selection("¿Qué es K1?").send(:compact_designator_chunks, chunks)

    assert_equal [ 1, 2, 3, 4 ], selected.map { |chunk| chunk[:metadata]["page_number"] }
    joined = selected.pluck(:content).join("\n")
    assert_includes joined, "24VAC SUBE"
    assert_includes joined, "24VDC"
    assert_includes joined, "SUBE/BAJA"
    assert_includes joined, "asociado a Q2"
    assert_not_includes joined, "SEARCH_ALIASES"
    assert_not_includes joined, "H14 aparece"
    selected.each do |chunk|
      assert_equal @source_uri, chunk[:metadata]["original_source_uri"]
      assert chunk[:chunk_sha256].present?
    end
  end

  test "exact designator lookup only treats the first table cell as the designator" do
    chunks = [
      designator_chunk(1, "| K1 | Contactor 24VAC SUBE |"),
      designator_chunk(2, "| Contacto auxiliar | K1 | otro dato |")
    ]
    selected = route_for_selection("¿Qué es K1?").send(:compact_designator_chunks, chunks)

    assert_equal [ "| K1 | Contactor 24VAC SUBE |" ], selected.pluck(:content)
  end

  test "unparsed exact lookup evidence falls back to the existing chunk selector" do
    prose = "El plano nombra K1 junto con otros relés del tablero, sin una fila de asignación."
    chunk = designator_chunk(2, prose)
    answer = "#{prose} [1]"
    generator = FakeGenerator.new(answer)
    rag_service = FakeRagService.new([ chunk ])

    outcome = build_route(
      question: "¿Qué es K1?",
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :answered, outcome.status
    assert_equal 1, generator.calls.size
    assert_includes generator.calls.first[:prompt], prose
    assert_not_includes generator.calls.first[:prompt], "turn the answer into a procedure"
  end

  test "exact designator lookup accepts a borne assignment and ignores a mention" do
    chunks = [
      designator_chunk(1, "borne 12: SEGURIDAD IN"),
      designator_chunk(2, "terminal 12 - SEGURIDAD IN"),
      designator_chunk(3, "ver borne 12 en el esquema"),
      designator_chunk(4, "la señal pasa por borne 12"),
      designator_chunk(5, "continuar desde terminal 12")
    ]
    selected = route_for_selection("¿Qué hay en el borne 12?").send(:compact_designator_chunks, chunks)

    assert_equal [ "borne 12: SEGURIDAD IN", "terminal 12 - SEGURIDAD IN" ], selected.pluck(:content)
  end

  test "exact designator lookup keeps both borne 12 assignments" do
    chunks = [
      designator_chunk(1, "| 12 | SEGURIDAD IN |"),
      designator_chunk(2, "| 12 | L Electrovalvula Bajando |")
    ]
    selected = route_for_selection("¿Qué hay en el borne 12?").send(:compact_designator_chunks, chunks)

    assert_equal [ "SEGURIDAD IN", "Electrovalvula Bajando" ], selected.map { |chunk| chunk[:content][/SEGURIDAD IN|Electrovalvula Bajando/] }
  end

  test "exact designator lookup keeps the K7 table row" do
    chunks = [
      designator_chunk(1, "- K7: Relé — bobina A2-A1. Vinculado a H4."),
      designator_chunk(2, "| K7 | Contactor 220vac Seguridad |")
    ]
    selected = route_for_selection("¿Qué función tiene K7?").send(:compact_designator_chunks, chunks)
    table = selected.find { |chunk| chunk[:content].include?("220vac") }

    assert table
    assert_includes table[:content], "Seguridad"
    assert_equal 2, table[:metadata]["page_number"]
  end

  test "exact designator lookup collapses equivalent Q1 values and keeps conflicts" do
    chunks = [
      designator_chunk(1, "- Q1: Interruptor automático 3 polos 25 A — alimentación trifásica. Designación de la hoja 2."),
      designator_chunk(2, "| Q1 | Interruptor automático 3 polos 25A |"),
      designator_chunk(3, "| Q1 | Elemento de maniobra/protección | DATA_NOT_AVAILABLE en este diagrama |"),
      designator_chunk(4, "- Q1: Interruptor/contactor — circuito Bomba hidráulica")
    ]
    selected = route_for_selection("¿Qué es Q1?").send(:compact_designator_chunks, chunks)
    joined = selected.pluck(:content).join("\n")

    assert_equal 3, selected.size
    assert_includes joined, "25A"
    assert_includes joined, "DATA_NOT_AVAILABLE"
    assert_includes joined, "Bomba hidráulica"
  end

  test "exact designator lookup collapses equivalent timer values" do
    chunks = [
      designator_chunk(1, "- T1: Relé temporizador (Modo E, t < 3 minutos) — ver tabla de designaciones, hoja 2."),
      designator_chunk(2, "| T1 | Relé Temporizador (Modo E y t<3 Minutos) |")
    ]
    selected = route_for_selection("¿Qué indica T1?").send(:compact_designator_chunks, chunks)

    assert_equal 1, selected.size
    assert_includes selected.first[:content], "t<3 Minutos"
  end

  test "exact designator lookup does not merge a timer fact with an unparsed wording" do
    chunks = [
      designator_chunk(1, "- T2: Relé temporizador tiempo breve."),
      designator_chunk(2, "| T2 | Relé Temporizador (Modo Wu y t<1 Seg) |")
    ]
    selected = route_for_selection("¿Qué indica T2?").send(:compact_designator_chunks, chunks)

    assert_equal 2, selected.size
  end

  test "exact designator lookup feeds compact evidence to one generation" do
    chunks = [
      designator_chunk(1, "- K1: Contactor/relé — bobina A1-A2. Involucrado en circuito SUBE/BAJA."),
      designator_chunk(2, "| K1 | Contactor 24VAC SUBE |"),
      designator_chunk(3, "| K1 | Contactor/relé | 24VDC |"),
      designator_chunk(4, "- K1: Contactor principal (asociado a Q2)")
    ]
    answer = chunks.each_with_index.map { |chunk, index| "#{chunk[:content]} [#{index + 1}]" }.join(" ")
    generator = FakeGenerator.new(answer)
    rag_service = FakeRagService.new(chunks)

    outcome = build_route(
      question: "¿Qué es K1?",
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :answered, outcome.status
    assert_equal 12, rag_service.calls.first[:number_of_results]
    prompt = generator.calls.first[:prompt]
    assert_includes prompt, "24VAC SUBE"
    assert_includes prompt, "24VDC"
    assert_includes prompt, "Page: 1"
    assert_includes prompt, "Page: 4"
    assert_includes prompt, "turn the answer into a procedure"
    assert_equal [ 1, 2, 3, 4 ], outcome.result[:citations].pluck(:page)
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, RagRetrievalProfile.new(entity_sources: [ "document" ], question: "¿Qué es K1?").number_of_results
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
      assert_equal 2, rag_service.calls.size
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
    assert_equal 2, off_service.calls.size
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

  test "generation prompt uses grounded synthesis when the flag is on for all accounts" do
    ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = "true"
    rag_service = FakeRagService.new([ neighbor_chunk ])
    generator = FakeGenerator.new("\"SERIE CAB. EXT. CERRADA\" [1]")

    outcome = build_route(
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    ).execute
    prompt = generator.calls.first[:prompt]

    assert_equal :answered, outcome.status
    assert_includes prompt, "# DISCRIMINATING QUESTION"
    assert_not_includes prompt, "Interpretación técnica:"
    assert_not_includes prompt, "STRICT_ONLY"
    assert_not_includes prompt, "GROUNDED_SYNTHESIS"
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

  # CG-D19 #A: the layer-3 orientation cites nothing. It is published without
  # sources instead of being replaced by the absence marker.
  test "prose without any citation marker is published with empty citations" do
    rag_service = FakeRagService.new([ neighbor_chunk ])
    prose = "Por la foto, esto parece el conjunto de fijación de los cables. No tengo en el manual recuperado una cota para estos resortes, así que no te recomendaría mover las tuercas."

    outcome = build_route(
      rag_service: rag_service,
      generator: FakeGenerator.new(prose),
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :answered, outcome.status
    assert_equal :answered, outcome.result[:route_outcome]
    assert_includes outcome.result[:answer], "no te recomendaría mover las tuercas"
    assert_not_includes outcome.result[:answer], "DATA_NOT_AVAILABLE"
    assert_empty outcome.result[:citations]
    assert_equal :uncited_prose, outcome.result.dig(:diagnostics, :outcome_reason)
    assert_equal 1, rag_service.calls.size
  end

  test "a single uncited sentence still abstains" do
    outcome = build_route(
      rag_service: FakeRagService.new([ neighbor_chunk ]),
      generator: FakeGenerator.new("El LED ABC12 corresponde a la serie principal."),
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal :abstained, outcome.status
    assert_equal :citation_failure, outcome.result.dig(:diagnostics, :outcome_reason)
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

  test "an identifier documented on several boards is answered per board and asks which one" do
    rag_service = FakeRagService.new(spm_board_chunks)
    raw_answer = "El significado de SPM depende de la placa que tenga delante.\n" \
      "En \"CARLOS SILVA TPR50\": \"SERIE PUERTAS CABINA - EXTERIORES\" [1].\n" \
      "En \"TWISTER TW - INAPELSA\": \"SERIE DE PUERTAS\" [2].\n" \
      "En \"DELTA +\": \"SERIE PUERTAS DE PISO\" [3].\n" \
      "¿Con qué placa está trabajando?"
    generator = FakeGenerator.new(raw_answer)

    outcome = with_family_guard("true") do
      build_route(
        question: "¿A qué serie corresponde el LED SPM?",
        rag_service: rag_service,
        generator: generator,
        expander: FakeExpander.new(nil)
      ).execute
    end
    prompt = generator.calls.first[:prompt]

    assert_equal :answered, outcome.status
    assert_equal 1, rag_service.calls.size
    assert_equal 3, outcome.result.dig(:retrieval_trace, :structured_route, :generation_chunks)
    assert_equal %w[spm-tpr50 spm-twister spm-delta],
                 outcome.result.dig(:diagnostics, :generation_chunks).pluck(:chunk_sha256)
    assert_includes prompt, "The evidence spans multiple distinct board families"
    assert_includes prompt, "ask which board it is"
    assert_includes prompt, "SERIE PUERTAS CABINA - EXTERIORES"
    assert_includes prompt, "SERIE DE PUERTAS"
    assert_includes prompt, "SERIE PUERTAS DE PISO"
    assert_equal [ 1, 2, 3 ], outcome.result[:citations].pluck(:number)
    assert_equal [ 9, 88, 91 ], outcome.result[:citations].pluck(:page)
    assert_includes outcome.result[:answer], "depende de la placa"
    assert_includes outcome.result[:answer], "SERIE PUERTAS DE PISO"
  end

  test "an identifier that passes the lexical equipment gate is still detected from the evidence" do
    rag_service = FakeRagService.new(dl2_board_chunks)
    raw_answer = "DL2 significa cosas distintas según la placa.\n" \
      "En \"LEVEL CONTROL 1B\": \"SERIE CERROJOS CERRADA\" [1].\n" \
      "En \"KDT 11\": \"SERIE PUERTAS EXTERIORES - CABINA\" [2].\n" \
      "¿Qué placa tiene delante?"
    generator = FakeGenerator.new(raw_answer)

    outcome = with_family_guard("true") do
      build_route(
        question: "¿Qué serie indica el LED DL2?",
        rag_service: rag_service,
        generator: generator,
        expander: FakeExpander.new(nil)
      ).execute
    end

    assert_equal :answered, outcome.status
    assert_equal 2, outcome.result.dig(:retrieval_trace, :structured_route, :generation_chunks)
    assert_includes generator.calls.first[:prompt], "The evidence spans multiple distinct board families"
    assert_equal [ 1, 2 ], outcome.result[:citations].pluck(:number)
  end

  test "the ambiguity guard reports the identifier and the boards it spans" do
    rag_service = FakeRagService.new(spm_board_chunks)
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    with_family_guard("true") do
      build_route(
        question: "¿A qué serie corresponde el LED SPM?",
        rag_service: rag_service,
        generator: FakeGenerator.new("\"SERIE DE PUERTAS\" [2]. \"SERIE PUERTAS DE PISO\" [3]."),
        expander: FakeExpander.new(nil)
      ).execute
    end

    line = output.string.lines.find { |entry| entry.include?('"event":"evidence_route"') }
    payload = JSON.parse(line.split("[PILOT_USAGE] ", 2).last)

    assert_equal true, payload["ambiguity_detected"]
    assert_equal "SPM", payload["ambiguity_identifier"]
    assert_equal [ "CARLOS SILVA TPR50", "TWISTER TW - INAPELSA", "DELTA +" ],
                 payload["ambiguity_families"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "the same evidence keeps today's single-family window with the guard off" do
    rag_service = FakeRagService.new(spm_board_chunks)
    generator = FakeGenerator.new("\"SERIE PUERTAS CABINA - EXTERIORES\" [1]")
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    outcome = with_family_guard("false") do
      build_route(
        question: "¿A qué serie corresponde el LED SPM?",
        rag_service: rag_service,
        generator: generator,
        expander: FakeExpander.new(nil)
      ).execute
    end
    prompt = generator.calls.first[:prompt]
    payload = JSON.parse(
      output.string.lines.find { |entry| entry.include?('"event":"evidence_route"') }
        .split("[PILOT_USAGE] ", 2).last
    )

    assert_equal :answered, outcome.status
    assert_equal 1, outcome.result.dig(:retrieval_trace, :structured_route, :generation_chunks)
    assert_equal [ "spm-tpr50" ], outcome.result.dig(:diagnostics, :generation_chunks).pluck(:chunk_sha256)
    assert_not_includes prompt, "The evidence spans multiple distinct board families"
    assert_not_includes prompt, "SERIE PUERTAS DE PISO"
    assert_not payload.key?("ambiguity_detected")
    assert_not payload.key?("ambiguity_families")
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "a question that names its board keeps the single-board window with the guard on" do
    question = "En la placa ARCA II, ¿qué serie indica el LED P32?"
    on_generator = FakeGenerator.new("\"SERIE CERROJOS EXTERIORES - CABINA\" [1]")
    off_generator = FakeGenerator.new("\"SERIE CERROJOS EXTERIORES - CABINA\" [1]")

    on = with_family_guard("true") do
      build_route(
        question: question,
        rag_service: FakeRagService.new(arca_board_chunks),
        generator: on_generator,
        expander: FakeExpander.new(nil)
      ).execute
    end
    off = with_family_guard("false") do
      build_route(
        question: question,
        rag_service: FakeRagService.new(arca_board_chunks),
        generator: off_generator,
        expander: FakeExpander.new(nil)
      ).execute
    end

    assert_equal :answered, on.status
    assert_equal [ "arca2" ], on.result.dig(:diagnostics, :generation_chunks).pluck(:chunk_sha256)
    assert_equal off_generator.calls.first[:prompt], on_generator.calls.first[:prompt]
    assert_not_includes on_generator.calls.first[:prompt], "multiple distinct board families"
  end

  test "a comparative question adds the second named board's chunk after the cover greedy" do
    route = route_for_selection(
      "En la placa ARCA básica, ¿qué serie indica el LED P32? ¿Significa lo mismo en ARCA III?"
    )

    selected = with_family_guard("true") { route.send(:select_generation_chunks, arca_board_chunks) }

    assert_equal %w[arca3 arca-basico], selected.pluck(:chunk_sha256)
  end

  test "the coverage pass is a no-op with the guard off" do
    route = route_for_selection(
      "En la placa ARCA básica, ¿qué serie indica el LED P32? ¿Significa lo mismo en ARCA III?"
    )

    selected = with_family_guard("false") { route.send(:select_generation_chunks, arca_board_chunks) }

    assert_equal %w[arca3], selected.pluck(:chunk_sha256)
  end

  test "a comparative question naming only one board does not trigger the coverage pass" do
    route = route_for_selection("En la placa ARCA II, ¿qué serie indica el LED P32?")

    selected = with_family_guard("true") { route.send(:select_generation_chunks, arca_board_chunks) }

    assert_equal %w[arca2], selected.pluck(:chunk_sha256)
  end

  test "a board named only through its Section line counts toward the coverage pass" do
    route = route_for_selection(
      "En la placa ARCA básica, ¿qué serie indica el LED P32? ¿Significa lo mismo en ARCA III?"
    )
    arca_basico_generic_heading = board_chunk(
      content: "**Document:** Manual\n**Page:** 62\n" \
               "**Section:** S7 — DIAGRAM: ARCA BASICO — Cadena de Seguridades\n\n" \
               "## LEDs de Estado — Tabla de Series\nP32 | SERIE CERROJOS CABINA - EXTERIORES",
      page: 62, section_identity: "ORONA", sha: "arca-basico-section-only"
    )
    arca3 = board_chunk(
      content: "## S4 — SAFETY SYSTEM: Diagrama de cadena de seguridades ARCA III\n" \
               "P32 | SERIE SEGURIDADES PRINCIPALES",
      page: 64, section_identity: "ORONA", sha: "arca3"
    )

    selected = with_family_guard("true") do
      route.send(:select_generation_chunks, [ arca_basico_generic_heading, arca3 ])
    end

    assert_equal %w[arca3 arca-basico-section-only], selected.pluck(:chunk_sha256)
  end

  test "the per-board window never exceeds the generation cap" do
    boards = Array.new(7) do |index|
      board_chunk(
        content: "## PLACA B#{index}Z — Diagrama de Series\nSPM | SERIE #{index}",
        page: index + 1,
        section_identity: "FABRICANTE #{index}",
        sha: "board-#{index}"
      )
    end
    route = route_for_selection("¿A qué serie corresponde el LED SPM?")
    ambiguity = Rag::FamilyAmbiguityDetector.new.call(
      question_analysis: Rag::QueryEntities.analyze("¿A qué serie corresponde el LED SPM?"),
      chunks: boards
    )

    assert ambiguity.ambiguous?
    assert_equal Rag::StructuredEvidenceRoute::MAX_GENERATION_CHUNKS,
                 route.send(:select_generation_chunks, boards, ambiguity: ambiguity).size
  end

  test "passes the account/user/session/correlation tracking hash to the generator for cost attribution" do
    rag_service = FakeRagService.new([ neighbor_chunk ])
    generator = FakeGenerator.new("ABC12 corresponde a la serie documentada. [1]")

    route = Rag::StructuredEvidenceRoute.build(
      question: "¿Qué indica el LED ABC12?",
      account: @account,
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      output_channel: :web,
      account_id: 7,
      user_id: 9,
      conversation_session_id: 11,
      correlation_id: "corr-tracking",
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    outcome = route.execute

    assert_equal :answered, outcome.status
    assert_equal(
      { account_id: 7, user_id: 9, conversation_session_id: 11, correlation_id: "corr-tracking" },
      generator.calls.first[:tracking]
    )
  end

  test "emits per-chunk evidence_route_context events with page, section_identity and source_uri" do
    rag_service = FakeRagService.new([ neighbor_chunk ])
    generator = FakeGenerator.new("ABC12 corresponde a la serie documentada. [1]")
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)

    build_route(rag_service: rag_service, generator: generator, expander: FakeExpander.new(nil)).execute

    contexts = output.string.lines
      .grep(/"event":"evidence_route_context"/)
      .map { |line| JSON.parse(line.split("[PILOT_USAGE] ", 2).last) }

    assert_equal 1, contexts.size
    assert_equal "neighbor-sha", contexts.first["chunk_sha256"]
    assert_equal 36, contexts.first["page"]
    assert_equal "SECTION-A", contexts.first["section_identity"]
    assert_equal @source_uri, contexts.first["source_uri"]
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
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

  test "explicit equipment identity overrides the episode" do
    body = "Igualar tensión MonoSpace."
    chunk = identity_chunk("KONE MonoSpace", body, page: 4)
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "Orona",
      needles: [ "Orona", "PBCM-V3" ],
      facts: [
        { "slot" => "manufacturer", "value" => "Orona", "source" => "photo", "correlation_id" => "photo:1" },
        { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "photo:1" }
      ]
    )
    route = Rag::StructuredEvidenceRoute.new(
      question: "ajuste",
      account: @account,
      entity_s3_uris: [],
      entity_sources: [],
      force_entity_filter: false,
      response_locale: :es,
      episode: mono_episode,
      equipment_identity: identity
    )

    scoped = nil
    with_identity_scope("true") { scoped = route.send(:scope_identity, [ chunk ]) }

    assert_includes scoped.first[:content], "REFERENCE ONLY — OTHER EQUIPMENT:"
    assert_not_includes scoped.first[:content], body
  end

  test "known equipment with only foreign chunks does not generate a documentary answer" do
    body = "Paso 11. Ajusta el interruptor Yida a 2,5 mm."
    chunk = identity_chunk("Fuji Yida Guía del Usuario Ascensor", body, page: 97)
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "Orona",
      needles: [ "Orona", "PBCM-V3" ],
      facts: [
        { "slot" => "manufacturer", "value" => "Orona", "source" => "photo", "correlation_id" => "photo:1" },
        { "slot" => "model", "value" => "PBCM-V3", "source" => "photo", "correlation_id" => "photo:1" }
      ]
    )
    generator = FakeGenerator.new("Según Yida ajusta a 2,5 mm. [1]")
    route = Rag::StructuredEvidenceRoute.new(
      question: "no nivela",
      account: @account,
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: FakeRagService.new([ chunk ]),
      generator: generator,
      expander: FakeExpander.new(nil),
      equipment_identity: identity
    )

    outcome = nil
    with_identity_scope("true") { outcome = route.execute }

    assert_equal 0, generator.calls.size
    assert_equal :abstained, outcome.status
    assert_equal "no_compatible", outcome.result[:equipment_identity_status]
    assert_not_includes outcome.result[:answer], body
    assert_equal [], outcome.result[:citations]
    assert_nil outcome.result[:doc_refs]
  end

  test "a disabled identity scope with known equipment does not generate" do
    chunk = identity_chunk("Fuji Yida", "Paso secreto Yida.", page: 4)
    identity = Rag::EquipmentIdentity.new(
      manufacturer: "Orona",
      needles: [ "Orona" ],
      facts: [
        { "slot" => "manufacturer", "value" => "Orona", "source" => "user", "correlation_id" => "query:1" }
      ]
    )
    generator = FakeGenerator.new("Procedimiento Yida. [1]")
    route = Rag::StructuredEvidenceRoute.new(
      question: "no nivela",
      account: @account,
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: FakeRagService.new([ chunk ]),
      generator: generator,
      expander: FakeExpander.new(nil),
      equipment_identity: identity
    )

    outcome = nil
    previous_scope = ENV.fetch("DOCUMENT_IDENTITY_SCOPE_ENABLED", nil)
    ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    outcome = route.execute

    assert_equal 0, generator.calls.size
    assert_equal "unavailable", outcome.result[:equipment_identity_status]
    assert_equal "scope_disabled", outcome.result[:equipment_identity_reason]
    assert_not_includes outcome.result[:answer], "Paso secreto"
  ensure
    if previous_scope.nil?
      ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    else
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = previous_scope
    end
  end

  test "identity scope strips other equipment before generation without a second retrieve" do
    question = "el modelo es MonoSpace, como se ajustan los resortes?"
    mono_body = "En MonoSpace igualar la tensión de los resortes de fijación de cables."
    yida_body = "Aflojar las tuercas del resorte y medir la tensión."
    paso_body = "Paso 11 del resorte del paracaídas. Colocar un suplemento de 2,5 mm."
    spt_body = "Procedimiento del manual SPT: comprimir el resorte del paracaídas."
    chunks = [
      identity_chunk("KONE MonoSpace", mono_body, page: 12),
      identity_chunk("Fuji Yida", yida_body, page: 53, source_uri: "s3://test-bucket/yida.pdf"),
      identity_chunk("Fuji Yida", paso_body, page: 58, source_uri: "s3://test-bucket/yida.pdf"),
      identity_chunk("Manual chino", spt_body, page: 78, section_identity: "SPT", source_uri: "s3://test-bucket/spt.pdf")
    ]
    rag_service = FakeRagService.new(chunks)
    generator = FakeGenerator.new("El manual MonoSpace no detalla el ajuste en este fragmento. [1]")
    route = Rag::StructuredEvidenceRoute.new(
      question: question,
      account: @account,
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil),
      episode: mono_episode
    )

    outcome = nil
    with_identity_scope("true") { outcome = route.execute }

    assert_equal 1, rag_service.calls.size
    assert_equal 1, generator.calls.size
    scoped = outcome.result.dig(:diagnostics, :retrieved_chunks)
    assert_equal 4, scoped.size
    assert_includes scoped[0][:content], mono_body
    assert_includes scoped[0][:content], "THIS JOB'S EQUIPMENT: KONE MonoSpace"
    [ yida_body, paso_body, spt_body ].each_with_index do |body, index|
      assert_includes scoped[index + 1][:content], "REFERENCE ONLY — OTHER EQUIPMENT:"
      assert_not_includes scoped[index + 1][:content], body
    end
    prompt = generator.calls.first[:prompt]
    assert_includes prompt, mono_body
    [ yida_body, paso_body, spt_body, "2,5 mm", "Paso 11" ].each do |foreign|
      assert_not_includes prompt, foreign
    end
    assert_not_includes prompt, "identity_unknown_reference"
    assert_not_includes prompt, "UNKNOWN EQUIPMENT IDENTITY"
  end

  test "unknown identity marks retrieved evidence as reference without a second call" do
    body = "Manual Código de Avería BLT Ascensor. Página 4. E18 fallo de nivelación."
    chunk = identity_chunk("Código de Avería BLT Ascensor", body, page: 4)
    answer = "El manual Código de Avería BLT Ascensor, página 4, documenta: E18 fallo de nivelación. No está confirmado que aplique a este equipo. [1]"
    rag_service = FakeRagService.new([ chunk ])
    generator = FakeGenerator.new(answer)
    route = Rag::StructuredEvidenceRoute.new(
      question: "la cabina queda desnivelada",
      account: @account,
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil),
      equipment_identity: nil,
      user_id: 9,
      conversation_session_id: 11,
      correlation_id: "query:structured-unknown"
    )

    outcome = nil
    events = capture_structured_events do
      with_identity_scope("true") { outcome = route.execute }
    end

    prompt = generator.calls.first[:prompt]
    scope = events.find { |event| event["event"] == "document_identity_scope" }

    assert_equal 1, rag_service.calls.size
    assert_equal 1, generator.calls.size
    assert_equal 9, rag_service.calls.first[:user_id]
    assert_equal 11, rag_service.calls.first[:conversation_session_id]
    assert_equal "structured_evidence_route", outcome.result[:generation_mode]
    assert_applicability_contract(prompt)
    assert_includes prompt, "UNCONFIRMED REFERENCE"
    assert_includes prompt, "Código de Avería BLT Ascensor"
    assert_includes prompt, "Page: 4"
    assert_includes prompt, body
    assert prompt.index("UNCONFIRMED REFERENCE") < prompt.index(body)
    assert_not_includes prompt, "THIS JOB'S EQUIPMENT:"
    assert_equal "not_required", scope["outcome_reason"]
    assert_equal "identity_unknown_reference", scope["evidence_applicability"]
    assert_equal 1, scope["results_count"]
    assert_equal 1, scope["contexts_delivered"]
    assert_equal :answered, outcome.status
    assert_includes outcome.result[:answer], "No está confirmado"
    assert_includes outcome.result[:answer], "[1]"
    assert_not_includes outcome.result[:answer], "Ajusta"
    assert outcome.result[:citations].any?
    assert outcome.result[:generation_context].none? { |token| token.include?("applicability") }
  end

  test "a pinned manual does not confirm identity on the structured route" do
    body = "Paso 11. Ajusta el interruptor Yida a 2,5 mm."
    chunk = identity_chunk("Fuji Yida", body, page: 11)
    rag_service = FakeRagService.new([ chunk ])
    generator = FakeGenerator.new("Referencia del manual Fuji Yida, página 11. No está confirmado para este equipo. [1]")
    route = Rag::StructuredEvidenceRoute.new(
      question: "la cabina queda desnivelada",
      account: @account,
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil),
      equipment_identity: nil
    )

    outcome = nil
    with_identity_scope("true") { outcome = route.execute }
    prompt = generator.calls.first[:prompt]

    assert_equal 1, rag_service.calls.size
    assert_equal 1, generator.calls.size
    assert_applicability_contract(prompt)
    assert_includes prompt, "UNCONFIRMED REFERENCE"
    assert_includes prompt, "Page: 11"
    assert_includes prompt, "Fuji Yida"
    assert_includes prompt, body
    assert prompt.index("UNCONFIRMED REFERENCE") < prompt.index(body)
    assert_not_includes prompt, "THIS JOB'S EQUIPMENT:"
    assert_equal "structured_evidence_route", outcome.result[:generation_mode]
    assert_not_equal "identity_unknown_reference", outcome.result[:generation_mode]
  end

  test "an inherited CEA15 identifier cannot put a foreign body in the prompt" do
    question = "el modelo es MonoSpace, como se ajustan los resortes?"
    prior = {
      "v" => 1,
      "episode_id" => "ep-cea",
      "updated_at" => Time.current.iso8601,
      "facts" => {
        "manufacturer" => {
          "status" => "known", "value" => "Fuji Yida", "source" => "user", "correlation_id" => "query:prior"
        }
      },
      "identifiers" => [ { "value" => "CEA15", "source" => "user", "correlation_id" => "query:prior" } ]
    }
    turn = Rag::ActiveEpisodeTurn.call(
      state: prior, text: question, now: Time.current, enabled: true, shared: false, correlation_id: "query:turn"
    )
    foreign = "Paso 11 del resorte del paracaídas en CEA15. Suplemento de 2,5 mm."
    chunks = [
      identity_chunk("KONE MonoSpace", "MonoSpace: tensión de resortes de fijación.", page: 4),
      identity_chunk("Manual CEA15", foreign, page: 12, source_uri: "s3://test-bucket/cea15.pdf")
    ]
    rag_service = FakeRagService.new(chunks)
    generator = FakeGenerator.new("No hay procedimiento MonoSpace en el fragmento. [1]")
    route = Rag::StructuredEvidenceRoute.new(
      question: question,
      account: @account,
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil),
      episode: turn.state
    )

    with_identity_scope("true") { route.execute }

    assert_equal [ "MonoSpace" ], Rag::DocumentIdentityScope.needles(turn.state)
    prompt = generator.calls.first[:prompt]
    assert_not_includes prompt, "2,5 mm"
    assert_not_includes prompt, "Paso 11"
    assert_includes prompt, "MonoSpace: tensión de resortes de fijación."
  end

  test "the MonoSpace regression does not send Fuji Yida or SPT procedures to generation" do
    question = "el modelo es MonoSpace, como se ajustan los resortes?"
    prior = {
      "v" => 1,
      "episode_id" => "ep_bb4b5f1650c50611",
      "updated_at" => Time.current.iso8601,
      "goal" => { "text" => "KONE no nivela" },
      "facts" => {
        "manufacturer" => {
          "status" => "known", "value" => "Fuji Yida", "source" => "user", "correlation_id" => "query:prior"
        }
      },
      "identifiers" => []
    }
    turn = Rag::ActiveEpisodeTurn.call(
      state: prior, text: question, now: Time.current, enabled: true, correlation_id: "query:turn"
    )
    paso_body = "Paso 11 del resorte del paracaídas. Colocar un suplemento de 2,5 mm."
    chunks = [
      identity_chunk("KONE MonoSpace", "MonoSpace: tensión de resortes de fijación.", page: 4),
      identity_chunk("Fuji Yida", "Aflojar el resorte del paracaídas.", page: 53, source_uri: "s3://test-bucket/yida.pdf"),
      identity_chunk("Fuji Yida", paso_body, page: 58, source_uri: "s3://test-bucket/yida.pdf"),
      identity_chunk("Manual chino", "Procedimiento SPT del resorte.", page: 78, section_identity: "SPT", source_uri: "s3://test-bucket/spt.pdf")
    ]
    rag_service = FakeRagService.new(chunks)
    generator = FakeGenerator.new("No hay un procedimiento MonoSpace en el fragmento citado. [1]")
    route = Rag::StructuredEvidenceRoute.new(
      question: question,
      account: @account,
      entity_s3_uris: [ @source_uri ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: rag_service,
      generator: generator,
      expander: FakeExpander.new(nil),
      episode: turn.state
    )

    with_identity_scope("true") { route.execute }

    assert_equal "MonoSpace", turn.state.dig("facts", "model", "value")
    assert_nil turn.state.dig("facts", "manufacturer")
    assert_equal [ "MonoSpace" ], Rag::DocumentIdentityScope.needles(turn.state)
    assert_equal 1, rag_service.calls.size
    prompt = generator.calls.first[:prompt]
    assert_not_includes prompt, "2,5 mm"
    assert_not_includes prompt, "Paso 11"
    assert_not_includes prompt, "Aflojar el resorte"
    assert_not_includes prompt, "Procedimiento SPT"
    assert_includes prompt, "MonoSpace: tensión de resortes de fijación."
  end

  private

  def with_audit_capture(value)
    previous = ENV["PILOT_AUDIT_CAPTURE"]
    value.nil? ? ENV.delete("PILOT_AUDIT_CAPTURE") : ENV["PILOT_AUDIT_CAPTURE"] = value
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    output.string
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
    previous.nil? ? ENV.delete("PILOT_AUDIT_CAPTURE") : ENV["PILOT_AUDIT_CAPTURE"] = previous
  end

  def parse_audit(line)
    JSON.parse(line.split("[PILOT_AUDIT] ", 2).last)
  end

  def with_family_guard(value)
    previous = ENV.fetch("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED", nil)
    ENV["RAG_FAMILY_AMBIGUITY_GUARD_ENABLED"] = value
    yield
  ensure
    if previous.nil?
      ENV.delete("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED")
    else
      ENV["RAG_FAMILY_AMBIGUITY_GUARD_ENABLED"] = previous
    end
  end

  def with_identity_scope(value)
    previous = ENV.fetch("DOCUMENT_IDENTITY_SCOPE_ENABLED", nil)
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = value
    yield
  ensure
    if previous.nil?
      ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    else
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = previous
    end
  end

  def mono_episode
    {
      "v" => 1,
      "episode_id" => "ep-mono",
      "updated_at" => Time.current.iso8601,
      "facts" => {
        "model" => {
          "status" => "known", "value" => "MonoSpace", "source" => "user", "correlation_id" => "query:turn"
        }
      },
      "identifiers" => []
    }
  end

  def identity_chunk(name, content, page:, section_identity: nil, source_uri: @source_uri)
    metadata = {
      "canonical_name" => name,
      "original_source_uri" => source_uri,
      "page_number" => page
    }
    metadata["section_identity"] = section_identity if section_identity
    synthetic_chunk(content, rank: page, sha: "id-#{page}-#{name.parameterize}").merge(metadata: metadata)
  end

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

  test "pinned designator rescue merges one extra retrieve inside the same pin" do
    assert_equal 3, RagRetrievalProfile::PINNED_DOCUMENT_RESULTS

    cases = [
      {
        question: "EM2000 hidráulico obstáculo",
        first: "Familia obstáculo de otra placa.",
        rescued: "OBSTACULO CONECTORES CN7 Y CN8 EN PLACA EM2000",
        facts: %w[CN7 CN8],
        intent: "EM2000",
        first_k: 3
      },
      {
        question: "EM4000 V1 obstáculo",
        first: "Obstáculo documentado en otra familia.",
        rescued: "EM4000 V1 obstáculo conectores XC4 y XC7",
        facts: %w[XC4 XC7],
        intent: "EM4000",
        first_k: 3
      },
      {
        question: "EDEL K2 cerrojos exteriores",
        first: "Cerrojos de otra placa.",
        rescued: "EDEL K2 LED serie 40 cerrojos exteriores",
        facts: [ "serie 40" ],
        intent: "EDEL K2",
        first_k: 3
      },
      {
        question: "EDEL K2 dos embarques",
        first: "Embarques de otra placa.",
        rescued: "EDEL K2 F1 fotocélula embarque 1 y F2 embarque 2",
        facts: %w[F1 F2],
        intent: "EDEL K2",
        first_k: 3
      },
      {
        question: "Falla la serie SCI del MR08",
        first: "Falla descrita sin el designador.",
        rescued: "MR08 serie SCI conectores CN-112 y CN-109",
        facts: %w[SCI CN-112 CN-109],
        intent: "SCI",
        first_k: RagRetrievalProfile::SAFETY_CRITICAL_RESULTS
      },
      {
        question: "Tengo encendida la luz H4. ¿Qué me está indicando?",
        first: "Otra lámpara del tablero.",
        rescued: "H4 luz piloto falla de seguridad",
        facts: [ "luz piloto", "falla de seguridad" ],
        intent: "H4",
        first_k: 3
      },
      {
        question: "¿Qué temporizador es T1?",
        first: "Otro componente del tablero.",
        rescued: "T1 modo E t < 3 min",
        facts: [ "modo E", "3 min" ],
        intent: "T1",
        first_k: 3
      },
      {
        question: "¿Qué temporizador es T2?",
        first: "Otro componente del tablero.",
        rescued: "T2 modo Wu t < 1 s",
        facts: [ "modo Wu", "1 s" ],
        intent: "T2",
        first_k: 3
      }
    ]

    cases.each do |example|
      service = SequencedRagService.new([
        [ synthetic_chunk(example[:first], rank: 1, sha: "first-#{example[:question].hash}") ],
        [ synthetic_chunk(example[:rescued], rank: 1, sha: "rescued-#{example[:question].hash}") ]
      ])
      generator = FakeGenerator.new("#{example[:rescued]}. [1] [2]")
      route = build_route(question: example[:question], rag_service: service, generator: generator, expander: FakeExpander.new(nil))

      assert route, example[:question]
      outcome = route.execute
      prompt = generator.calls.first[:prompt]

      assert_equal :answered, outcome.status, example[:question]
      assert_equal 2, service.calls.size, example[:question]
      assert_equal example[:first_k], service.calls.first[:number_of_results], example[:question]
      assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, service.calls.last[:number_of_results], example[:question]
      assert_equal [ @source_uri ], service.calls.first[:entity_s3_uris]
      assert_equal [ @source_uri ], service.calls.last[:entity_s3_uris]
      assert_equal true, service.calls.first[:force_entity_filter]
      assert_equal true, service.calls.last[:force_entity_filter]
      assert_includes service.calls.last[:question], example[:intent], example[:question]
      assert_includes prompt, example[:first], example[:question]
      example[:facts].each { |fact| assert_includes prompt, fact, example[:question] }
    end
  end

  test "an elliptical Edel-k2 rescue keeps the current goal and drops historical identifiers" do
    episode = {
      "goal" => { "text" => "EDEL K2 cerrojos exteriores" },
      "identifiers" => [
        { "value" => "EM2000", "source" => "user" },
        { "value" => "DL4", "source" => "user" }
      ]
    }
    service = SequencedRagService.new([
      [ synthetic_chunk("Placa distinta, sin el modelo.", rank: 1, sha: "other-board") ],
      [ synthetic_chunk("EDEL K2 LED serie 40 cerrojos exteriores", rank: 1, sha: "edel-sheet") ]
    ])
    generator = FakeGenerator.new("serie 40. [1] [2]")
    route = build_route(
      question: "EM2000 DL4 CTA ALJO\nEDEL K2 cerrojos exteriores\nEdel-k2",
      raw_question: "Edel-k2",
      episode: episode,
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    assert route
    route.execute
    rescue_query = service.calls.last[:question]

    assert_equal 2, service.calls.size
    assert_includes rescue_query, "cerrojos exteriores"
    assert_includes rescue_query, "Edel-k2"
    %w[EM2000 DL4 CTA ALJO].each { |token| assert_not_includes rescue_query, token }
    assert_includes generator.calls.first[:prompt], "Placa distinta"
    assert_includes generator.calls.first[:prompt], "serie 40"
  end

  test "a self-contained rescue does not prepend the goal when the goal is the turn" do
    question = "EM4000 V1 obstáculo"
    service = SequencedRagService.new([
      [ synthetic_chunk("Otra familia de obstáculo.", rank: 1, sha: "other-obstacle") ],
      [ synthetic_chunk("EM4000 V1 XC4 XC7", rank: 1, sha: "em4000-sheet") ]
    ])
    route = build_route(
      question: question,
      raw_question: question,
      episode: { "goal" => { "text" => question } },
      rag_service: service,
      generator: FakeGenerator.new("XC4 XC7. [1] [2]"),
      expander: FakeExpander.new(nil)
    )

    route.execute

    assert_equal "EM4000 V1", service.calls.last[:question]
    assert_not_includes service.calls.last[:question], "EM2000"
  end

  test "a designator already in the first window does not retrieve again" do
    service = FakeRagService.new([ synthetic_chunk("H4 es la luz piloto del tablero.", rank: 1, sha: "h4-present") ])
    route = build_route(
      question: "¿Qué es H4?",
      rag_service: service,
      generator: FakeGenerator.new("H4 es la luz piloto. [1]"),
      expander: FakeExpander.new(nil)
    )

    route.execute

    assert_equal 1, service.calls.size
    assert_equal RagRetrievalProfile::STRUCTURED_MAPPING_RESULTS, service.calls.first[:number_of_results]
  end

  test "a missed second designator retrieve does not issue a third" do
    service = SequencedRagService.new([
      [ synthetic_chunk("Primera ventana sin el modelo.", rank: 1, sha: "miss-1") ],
      [ synthetic_chunk("Segunda ventana todavía sin el modelo.", rank: 1, sha: "miss-2") ]
    ])
    generator = FakeGenerator.new("Sin el conector en estas páginas. [1]")
    route = build_route(
      question: "EM4000 V1 obstáculo",
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    outcome = route.execute

    assert_equal :answered, outcome.status
    assert_equal 2, service.calls.size
    assert_includes generator.calls.first[:prompt], "Primera ventana"
    assert_includes generator.calls.first[:prompt], "Segunda ventana"
  end

  test "rescue dedupes a chunk that comes back in both windows" do
    shared = synthetic_chunk("Ventana compartida EM4000.", rank: 1, sha: "shared-sha")
    rescued = synthetic_chunk("EM4000 V1 XC4", rank: 2, sha: "xc4-sha")
    service = SequencedRagService.new([ [ shared ], [ shared, rescued ] ])
    route = build_route(
      question: "EM4000 V1 obstáculo",
      rag_service: service,
      generator: FakeGenerator.new("XC4. [1] [2]"),
      expander: FakeExpander.new(nil)
    )

    outcome = route.execute
    shas = outcome.result.dig(:diagnostics, :generation_chunks).pluck(:chunk_sha256)

    assert_equal 2, service.calls.size
    assert_equal %w[shared-sha xc4-sha], shas
  end

  test "a superior label without a borne number does not block the borne question" do
    service = SequencedRagService.new([
      [ synthetic_chunk("| MICRO RUEDA NIVEL SUPERIOR | Descripción |", rank: 1, sha: "rueda") ],
      [ synthetic_chunk("| 31 | Micro nivel superior |", rank: 1, sha: "sheet-2") ]
    ])
    route = build_route(
      question: "¿A qué borne corresponde el micro de nivel superior?",
      rag_service: service,
      generator: FakeGenerator.new("Micro nivel superior. [1] [2]"),
      expander: FakeExpander.new(nil)
    )

    route.execute

    assert_equal 2, service.calls.size
    assert_equal "micro de nivel superior", service.calls.last[:question]
  end

  test "a nivel row without the asked function does not block mapping rescue" do
    question = "¿A qué borne corresponde la llamada de nivel 1?"
    service = SequencedRagService.new([
      [ synthetic_chunk("| 9 | Seguridad Puerta nivel 1 |", rank: 1, sha: "puerta") ],
      [ synthetic_chunk("| 33 | Llamada nivel 1 |", rank: 1, sha: "sheet-2") ]
    ])
    route = build_route(
      question: question,
      rag_service: service,
      generator: FakeGenerator.new("Llamada nivel 1. [1] [2]"),
      expander: FakeExpander.new(nil)
    )

    route.execute

    assert_equal 2, service.calls.size
    assert_equal "llamada de nivel 1", service.calls.last[:question]
  end

  test "seguridad IN does not cover a Seguridad OUT question" do
    service = SequencedRagService.new([
      [ synthetic_chunk("| 23 | SEGURIDAD IN |", rank: 1, sha: "in-row") ],
      [ synthetic_chunk("| 23 | Seguridad OUT |", rank: 1, sha: "out-row") ]
    ])
    route = build_route(
      question: "¿A qué borne corresponde Seguridad OUT?",
      rag_service: service,
      generator: FakeGenerator.new("Seguridad OUT. [1] [2]"),
      expander: FakeExpander.new(nil)
    )

    route.execute

    assert_equal 2, service.calls.size
    assert_equal "Seguridad OUT", service.calls.last[:question]
  end

  test "bornera location enters mapping rescue with the measured anchor phrase" do
    question = "¿Dónde está conectada Seguridad IN en la bornera del tablero?"
    service = SequencedRagService.new([
      [ synthetic_chunk("Descripción del tablero sin la fila pedida.", rank: 1, sha: "miss") ],
      [ synthetic_chunk("| 24 | Seguridad IN |", rank: 1, sha: "sheet-2") ]
    ])
    generator = FakeGenerator.new("Seguridad IN. [1] [2]")
    route = build_route(
      question: question,
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    assert route
    route.execute
    rescue_call = service.calls.last

    assert_equal 2, service.calls.size
    assert_equal question, service.calls.first[:question]
    assert_equal "conectada Seguridad IN bornera tablero", rescue_call[:question]
    assert_not_equal service.calls.first[:question].squish.downcase, rescue_call[:question].squish.downcase
    assert_equal [ @source_uri ], rescue_call[:entity_s3_uris]
    assert_equal true, rescue_call[:force_entity_filter]
    assert_equal 3, rescue_call[:number_of_results]
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, rescue_call[:number_of_results]
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, service.calls.first[:number_of_results]
    assert_includes generator.calls.first[:prompt], "| 24 | Seguridad IN |"
  end

  test "a location question without the bornera stem stays ineligible" do
    assert_nil build_route(question: "¿Dónde está el cuadro de maniobra?")
  end

  test "both borne associations in the first window stay one retrieve" do
    question = "¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?"
    sheet = synthetic_chunk("| 23 | Seguridad OUT |\n| 24 | Seguridad IN |", rank: 2, sha: "sheet-2")
    distractor = synthetic_chunk(
      "Cuáles son los bornes de Seguridad en el pasillo.\n| 1 | Seg In |\n| 11 | Seg Out |",
      rank: 1,
      sha: "page-5"
    )
    service = FakeRagService.new([ distractor, sheet ])
    generator = FakeGenerator.new("Seguridad OUT y Seguridad IN. [1]")
    route = build_route(
      question: question,
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    assert route
    route.execute

    assert_equal 1, service.calls.size
    assert_includes generator.calls.first[:prompt], "| 23 | Seguridad OUT |"
    assert_includes generator.calls.first[:prompt], "| 24 | Seguridad IN |"
  end

  test "one polarity row leaves the other mapping uncovered" do
    question = "¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?"
    route = route_for_selection(question)
    out_only = [ synthetic_chunk("| 23 | Seguridad OUT |", rank: 1, sha: "out") ]
    in_only = [ synthetic_chunk("| 24 | Seguridad IN |", rank: 1, sha: "in") ]
    groups = route.send(:borne_mapping_groups, question)

    assert_equal 2, groups.size
    assert route.send(:mapping_group_covered?, out_only, groups[0])
    assert_not route.send(:mapping_group_covered?, out_only, groups[1])
    assert route.send(:mapping_group_covered?, in_only, groups[1])
    assert_not route.send(:mapping_group_covered?, in_only, groups[0])
    assert_not route.send(:explicit_row_covered?, out_only)
    assert_not route.send(:explicit_row_covered?, in_only)

    service = SequencedRagService.new([
      out_only,
      [ synthetic_chunk("| 24 | Seguridad IN |", rank: 1, sha: "in-rescue") ]
    ])
    build_route(
      question: question,
      rag_service: service,
      generator: FakeGenerator.new("Fila parcial. [1] [2]"),
      expander: FakeExpander.new(nil)
    ).execute

    assert_equal 2, service.calls.size
  end

  test "mentioning both names without an explicit assignment leaves them uncovered" do
    out_in = "¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?"
    micros = "¿Cuáles son los bornes del micro de nivel inferior y del micro de nivel superior?"
    route = route_for_selection(out_in)
    mention = [ synthetic_chunk("Seguridad OUT y Seguridad IN están en la bornera.", rank: 1, sha: "mention") ]
    micro_mention = [ synthetic_chunk("El micro inferior y el micro superior están en la bornera.", rank: 1, sha: "micros") ]
    micro_rows = [ synthetic_chunk("| 30 | Micro nivel inferior |\n| 31 | Micro nivel superior |", rank: 1, sha: "micro-rows") ]

    assert_not route.send(:explicit_row_covered?, mention)
    assert_not route_for_selection(micros).send(:explicit_row_covered?, micro_mention)
    assert route_for_selection(micros).send(:explicit_row_covered?, micro_rows)
    assert_equal micros.sub(/[?¿]+\z/, ""), route_for_selection(micros).send(:mapping_rescue_query)
  end

  test "single mapping lookups keep one retrieve when their row is present" do
    cases = {
      "¿A qué borne corresponde el micro de nivel inferior?" => "| 30 | Micro nivel inferior |",
      "¿A qué borne corresponde el micro de nivel superior?" => "| 31 | Micro nivel superior |",
      "¿A qué borne corresponde la llamada de nivel 1?" => "| 33 | Llamada nivel 1 |",
      "¿A qué borne corresponde la llamada de nivel 2?" => "| 34 | Llamada nivel 2 |",
      "¿A qué borne corresponde Seguridad OUT?" => "| 23 | Seguridad OUT |",
      "¿A qué borne corresponde Seguridad IN?" => "| 24 | Seguridad IN |",
      "¿A qué borne corresponde Presostato OUT?" => "| 25 | Presostato OUT |",
      "¿A qué borne corresponde Presostato IN?" => "| 26 | Presostato IN |"
    }

    cases.each do |question, row|
      service = FakeRagService.new([
        synthetic_chunk(terminal_sheet(row), rank: 1, sha: Digest::SHA256.hexdigest(question))
      ])
      generator = FakeGenerator.new("Fila. [1]")
      route = build_route(
        question: question,
        rag_service: service,
        generator: generator,
        expander: FakeExpander.new(nil)
      )

      assert route, question
      route.execute
      assert_equal 1, service.calls.size, question
      assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, service.calls.first[:number_of_results], question
      assert_includes generator.calls.first[:prompt], row, question
    end
  end

  test "a diagram position with the label and a number does not cover a borne mapping" do
    diagram = <<~TEXT
      SECCIÓN LÍNEA DE SEGURIDAD
      | Posición | Etiqueta visible en diagrama |
      |---|---|
      | 11 | Seg Out |
      | 1 | Seg In |
      | 11 | Seguridad OUT |
      | 1 | Seguridad IN |
    TEXT
    out = route_for_selection("¿A qué borne corresponde Seguridad OUT?")
    inn = route_for_selection("¿A qué borne corresponde Seguridad IN?")
    chunk = synthetic_chunk(diagram, rank: 5, sha: "diagram")

    assert_not out.send(:explicit_row_covered?, [ chunk ])
    assert_not inn.send(:explicit_row_covered?, [ chunk ])
  end

  test "a diagram position does not cancel borne rescue and stays in generation" do
    diagram = <<~TEXT
      SECCIÓN LÍNEA DE SEGURIDAD
      | Posición | Etiqueta visible en diagrama |
      |---|---|
      | 11 | Seg Out |
    TEXT
    service = SequencedRagService.new([
      [ synthetic_chunk(diagram, rank: 1, sha: "diagram") ],
      [ synthetic_chunk(terminal_sheet("| 23 | Seguridad OUT |"), rank: 1, sha: "terminals") ]
    ])
    generator = FakeGenerator.new("Seguridad OUT. [1] [2]")
    route = build_route(
      question: "¿A qué borne corresponde Seguridad OUT?",
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    route.execute
    prompt = generator.calls.first[:prompt]

    assert_equal 2, service.calls.size
    assert_equal "Seguridad OUT", service.calls.last[:question]
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, service.calls.first[:number_of_results]
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, service.calls.last[:number_of_results]
    assert_equal [ @source_uri ], service.calls.last[:entity_s3_uris]
    assert_equal true, service.calls.last[:force_entity_filter]
    assert_includes prompt, "| 11 | Seg Out |"
    assert_includes prompt, "| 23 | Seguridad OUT |"
  end

  test "a diagram position for the other polarity does not cancel borne rescue" do
    diagram = <<~TEXT
      SECCIÓN LÍNEA DE SEGURIDAD
      | Posición | Etiqueta visible en diagrama |
      |---|---|
      | 1 | Seg In |
    TEXT
    service = SequencedRagService.new([
      [ synthetic_chunk(diagram, rank: 1, sha: "diagram-in") ],
      [ synthetic_chunk(terminal_sheet("| 24 | Seguridad IN |"), rank: 1, sha: "terminals-in") ]
    ])
    generator = FakeGenerator.new("Seguridad IN. [1] [2]")
    route = build_route(
      question: "¿A qué borne corresponde Seguridad IN?",
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    route.execute

    assert_equal 2, service.calls.size
    assert_equal "Seguridad IN", service.calls.last[:question]
    assert_includes generator.calls.first[:prompt], "| 1 | Seg In |"
    assert_includes generator.calls.first[:prompt], "| 24 | Seguridad IN |"
  end

  test "a terminal table covers a single borne mapping without section metadata" do
    question = "¿A qué borne corresponde Seguridad OUT?"
    sheet = synthetic_chunk(terminal_sheet("| 23 | Seguridad OUT |"), rank: 2, sha: "terminals")
    route = route_for_selection(question)

    assert_not sheet[:metadata].values.any? { |value| value.to_s.match?(/borne|terminal/i) }
    assert route.send(:explicit_row_covered?, [ sheet ])
  end

  test "section metadata can show the terminal role without a table header" do
    question = "¿A qué borne corresponde Seguridad OUT?"
    labelled = synthetic_chunk("| 23 | Seguridad OUT |", rank: 2, sha: "meta").merge(
      metadata: { "section" => "Bloque de terminales" }
    )
    bare = synthetic_chunk("| 23 | Seguridad OUT |", rank: 2, sha: "bare")
    route = route_for_selection(question)

    assert route.send(:explicit_row_covered?, [ labelled ])
    assert_not route.send(:explicit_row_covered?, [ bare ])
  end

  test "an ambiguous borne row stays beside the terminal table and does not add a retrieve" do
    diagram = synthetic_chunk(<<~TEXT, rank: 1, sha: "diagram-kept")
      SECCIÓN LÍNEA DE SEGURIDAD
      | Posición | Etiqueta visible en diagrama |
      |---|---|
      | 11 | Seguridad OUT |
    TEXT
    sheet = synthetic_chunk(terminal_sheet("| 23 | Seguridad OUT |"), rank: 2, sha: "terminals-kept")
    service = FakeRagService.new([ diagram, sheet ])
    generator = FakeGenerator.new("Seguridad OUT. [1]")
    route = build_route(
      question: "¿A qué borne corresponde Seguridad OUT?",
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    route.execute
    prompt = generator.calls.first[:prompt]

    assert_equal 1, service.calls.size
    assert_includes prompt, "| 23 | Seguridad OUT |"
    assert_includes prompt, "| 11 | Seguridad OUT |"
  end

  test "SUBE and BAJA questions stay outside the mapping route" do
    assert_nil build_route(question: "Elemont MH, ¿cuál es el relé de SUBE?")
    assert_nil build_route(question: "¿Y para BAJA cuál es el relé?")
    assert_nil build_route(question: "¿Qué relés corresponden a SUBE y BAJA en este tablero?")
  end

  test "T1 and T2 together stay on the designator span" do
    question = "¿Cómo están configurados T1 y T2?"
    service = FakeRagService.new([
      synthetic_chunk("T1 temporizador\nT2 temporizador", rank: 1, sha: "timers")
    ])
    route = build_route(
      question: question,
      rag_service: service,
      generator: FakeGenerator.new("T1 y T2. [1]"),
      expander: FakeExpander.new(nil)
    )

    assert route
    route.execute

    assert_equal 1, service.calls.size
    assert_equal :designator, route.retrieval_report[:mode]
    assert_equal "T1 y T2", route.send(:designator_rescue_query)
  end

  test "designator rescue names turn identifiers when span prose or an attribution connector empties the window" do
    assert_equal 3, RagRetrievalProfile::PINNED_DOCUMENT_RESULTS

    {
      "En EDEL K2, ¿qué función tienen F1 y F2 en los embarques?" => "EDEL K2 F1 F2",
      "¿qué indican F1 y F2?" => "F1 F2",
      "En EDEL K2 con dos embarques, ¿qué fotocélulas identifica el manual para cada embarque?" => "EDEL K2",
      "EDEL K2 cerrojos exteriores" => "EDEL K2",
      "Falla la serie SCI del MR08" => "SCI del MR08",
      "EM4000 V1 obstáculo" => "EM4000 V1",
      "Tengo encendida la luz H4. ¿Qué me está indicando?" => "H4",
      "¿Qué temporizador es T1?" => "T1",
      "¿Qué temporizador es T2?" => "T2",
      "¿Cómo están configurados T1 y T2?" => "T1 y T2"
    }.each do |question, rescue_query|
      route = build_route(
        question: question,
        rag_service: FakeRagService.new([]),
        generator: FakeGenerator.new("x"),
        expander: FakeExpander.new(nil)
      )

      assert route, question
      assert_equal rescue_query, route.send(:designator_rescue_query), question
    end
  end

  test "F1 and F2 function question retrieves the identifier names once inside the pin" do
    service = SequencedRagService.new([
      [ synthetic_chunk("Otra placa, sin los designadores.", rank: 1, sha: "miss-funcion") ],
      [ synthetic_chunk("| F1  | FOTOCELULA EMBARQUE 1 |\n| F2  | FOTOCELULA EMBARQUE 2 |", rank: 1, sha: "p25-funcion") ]
    ])
    generator = FakeGenerator.new("F1 FOTOCELULA EMBARQUE 1. F2 FOTOCELULA EMBARQUE 2. [1] [2]")
    route = build_route(
      question: "En EDEL K2, ¿qué función tienen F1 y F2 en los embarques?",
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    outcome = route.execute
    prompt = generator.calls.first[:prompt]

    assert_equal :answered, outcome.status
    assert_equal 2, service.calls.size
    assert_equal "EDEL K2 F1 F2", service.calls.last[:question]
    assert_pinned_designator_call(service.calls.first)
    assert_pinned_designator_call(service.calls.last)
    assert_includes prompt, "| F1  | FOTOCELULA EMBARQUE 1 |"
    assert_includes prompt, "| F2  | FOTOCELULA EMBARQUE 2 |"
  end

  test "F1 and F2 attribution question retrieves the designators without the connector" do
    service = SequencedRagService.new([
      [ synthetic_chunk("Otra placa, sin los designadores.", rank: 1, sha: "miss-indican") ],
      [ synthetic_chunk("| F1  | FOTOCELULA EMBARQUE 1 |\n| F2  | FOTOCELULA EMBARQUE 2 |", rank: 1, sha: "p25-indican") ]
    ])
    generator = FakeGenerator.new("F1 FOTOCELULA EMBARQUE 1. F2 FOTOCELULA EMBARQUE 2. [1] [2]")
    route = build_route(
      question: "¿qué indican F1 y F2?",
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    outcome = route.execute
    prompt = generator.calls.first[:prompt]

    assert_equal :answered, outcome.status
    assert_equal 2, service.calls.size
    assert_equal "F1 F2", service.calls.last[:question]
    assert_pinned_designator_call(service.calls.first)
    assert_pinned_designator_call(service.calls.last)
    assert_includes prompt, "| F1  | FOTOCELULA EMBARQUE 1 |"
    assert_includes prompt, "| F2  | FOTOCELULA EMBARQUE 2 |"
  end

  test "photocell landing question does not retrieve again when the first window already has the model page" do
    page = synthetic_chunk(
      "EDEL K2\n| F1  | FOTOCELULA EMBARQUE 1 |\n| F2  | FOTOCELULA EMBARQUE 2 |",
      rank: 25,
      sha: "p25-control"
    )
    generator = FakeGenerator.new("F1 FOTOCELULA EMBARQUE 1. F2 FOTOCELULA EMBARQUE 2. [1]")
    service = FakeRagService.new([ page ])
    route = build_route(
      question: "En EDEL K2 con dos embarques, ¿qué fotocélulas identifica el manual para cada embarque?",
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    outcome = route.execute
    prompt = generator.calls.first[:prompt]

    assert_equal :answered, outcome.status
    assert_equal 1, service.calls.size
    assert_equal "EDEL K2", route.send(:designator_rescue_query)
    assert_pinned_designator_call(service.calls.first)
    assert_includes prompt, "| F1  | FOTOCELULA EMBARQUE 1 |"
    assert_includes prompt, "| F2  | FOTOCELULA EMBARQUE 2 |"
  end

  test "a covered F1 and F2 function question does not retrieve again" do
    page = synthetic_chunk(
      "EDEL K2\n| F1  | FOTOCELULA EMBARQUE 1 |\n| F2  | FOTOCELULA EMBARQUE 2 |",
      rank: 25,
      sha: "p25-covered-funcion"
    )
    service = FakeRagService.new([ page ])
    route = build_route(
      question: "En EDEL K2, ¿qué función tienen F1 y F2 en los embarques?",
      rag_service: service,
      generator: FakeGenerator.new("F1 FOTOCELULA EMBARQUE 1. F2 FOTOCELULA EMBARQUE 2. [1]"),
      expander: FakeExpander.new(nil)
    )

    route.execute

    assert_equal 1, service.calls.size
    assert_pinned_designator_call(service.calls.first)
  end

  test "a covered F1 and F2 attribution question does not retrieve again" do
    page = synthetic_chunk(
      "| F1  | FOTOCELULA EMBARQUE 1 |\n| F2  | FOTOCELULA EMBARQUE 2 |",
      rank: 25,
      sha: "p25-covered-indican"
    )
    service = FakeRagService.new([ page ])
    route = build_route(
      question: "¿qué indican F1 y F2?",
      rag_service: service,
      generator: FakeGenerator.new("F1 FOTOCELULA EMBARQUE 1. F2 FOTOCELULA EMBARQUE 2. [1]"),
      expander: FakeExpander.new(nil)
    )

    route.execute

    assert_equal 1, service.calls.size
    assert_pinned_designator_call(service.calls.first)
  end

  test "a missed F1 and F2 identifier rescue does not issue a third retrieve" do
    service = SequencedRagService.new([
      [ synthetic_chunk("Primera ventana vacía.", rank: 1, sha: "empty-1") ],
      [ synthetic_chunk("Segunda ventana vacía.", rank: 1, sha: "empty-2") ]
    ])
    route = build_route(
      question: "¿qué indican F1 y F2?",
      rag_service: service,
      generator: FakeGenerator.new("Sin la fila en estas páginas. [1]"),
      expander: FakeExpander.new(nil)
    )

    route.execute

    assert_equal 2, service.calls.size
    assert_equal "F1 F2", service.calls.last[:question]
    assert_equal [ @source_uri ], service.calls.last[:entity_s3_uris]
    assert_equal true, service.calls.last[:force_entity_filter]
  end

  test "mapping lookup rescues once when the first window has no explicit row" do
    question = "¿A qué borne corresponde el micro de nivel inferior?"
    service = SequencedRagService.new([
      [ synthetic_chunk("Descripción general del tablero sin filas.", rank: 1, sha: "prose") ],
      [ synthetic_chunk("| 30 | MICRO NIVEL INFERIOR |", rank: 1, sha: "sheet-2") ]
    ])
    generator = FakeGenerator.new("MICRO NIVEL INFERIOR. [1] [2]")
    route = build_route(
      question: question,
      rag_service: service,
      generator: generator,
      expander: FakeExpander.new(nil)
    )

    assert route
    outcome = route.execute
    rescue_query = service.calls.last[:question]

    assert_equal 2, service.calls.size
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, service.calls.first[:number_of_results]
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, service.calls.last[:number_of_results]
    assert_equal [ @source_uri ], service.calls.last[:entity_s3_uris]
    assert_equal true, service.calls.last[:force_entity_filter]
    assert_equal "micro de nivel inferior", rescue_query
    assert_not_includes rescue_query, "Seguridad"
    assert_includes generator.calls.first[:prompt], "sin filas"
    assert_includes generator.calls.first[:prompt], "| 30 | MICRO NIVEL INFERIOR |"
    assert_equal :answered, outcome.status
  end

  test "chunk_p1_2 explicit rows do not open a second mapping retrieve" do
    bornera = synthetic_chunk(
      Rails.root.join("test/fixtures/files/elemont/chunk_p1_2_current.txt").read,
      rank: 1,
      sha: "chunk-p1-2"
    )
    cases = {
      "¿A qué borne corresponde Seguridad OUT?" => [ "| 13 | SEGURIDAD OUT |", "| 22 | SEGURIDAD OUT" ],
      "¿A qué borne corresponde Seguridad IN?" => [ "| 12 | SEGURIDAD IN |", "| 23 | SEGURIDAD IN" ],
      "¿A qué borne corresponde el presostato?" => [ "| 14 | PRESOSTATO IN |", "| 15 | PRESOSTATO OUT |", "| 24 | PRESOSTATO IN |", "| 25 | PRESOSTATO OUT |" ],
      "¿A qué borne corresponde el micro de nivel inferior?" => [ "| 26 | LIMITE INFERIOR |" ],
      "¿A qué borne corresponde el micro de nivel superior?" => [ "| 27 | LIMITE SUPERIOR |" ],
      "¿A qué borne corresponde la llamada de nivel 1?" => [ "| 31 | LLAMADA NIVEL 1 |" ],
      "¿A qué borne corresponde la llamada de nivel 2?" => [ "| 32 | LLAMADA NIVEL 2 |" ]
    }

    cases.each do |question, rows|
      service = FakeRagService.new([ bornera ])
      generator = FakeGenerator.new("Fila del plano. [1]")
      route = build_route(question: question, rag_service: service, generator: generator, expander: FakeExpander.new(nil))

      assert route, question
      route.execute
      prompt = generator.calls.first[:prompt]

      assert_equal 1, service.calls.size, question
      rows.each { |row| assert_includes prompt, row, question }
    end
  end

  test "chunk_p1_2 already contains H4 T1 and T2 so the designator rescue does not run" do
    bornera = synthetic_chunk(
      Rails.root.join("test/fixtures/files/elemont/chunk_p1_2_current.txt").read,
      rank: 1,
      sha: "chunk-p1-2"
    )
    {
      "Tengo encendida la luz H4. ¿Qué me está indicando?" => "H4: Lámpara",
      "¿Qué es T1?" => "T1: Transformador",
      "¿Qué es T2?" => "T2: Transformador"
    }.each do |question, marker|
      service = FakeRagService.new([ bornera ])
      route = build_route(
        question: question,
        rag_service: service,
        generator: FakeGenerator.new("#{marker}. [1]"),
        expander: FakeExpander.new(nil)
      )

      assert route, question
      route.execute

      assert_equal 1, service.calls.size, question
    end
  end

  test "ordinary manual questions do not enter the pinned rescue" do
    [
      "¿Dónde está el cuadro de maniobra?",
      "¿Qué elementos aparecen en esa línea?",
      "¿Cómo reviso la cadena de seguridad?",
      "¿Cómo se ilumina el foso?",
      "Micro nivel inferior"
    ].each do |question|
      assert_nil build_route(question: question), question
    end
  end

  test "a mapping question with the flag off or with two pins does not build" do
    question = "¿A qué borne corresponde Seguridad OUT?"

    assert_nil build_route(question: question, entity_s3_uris: [])
    assert_nil build_route(question: question, entity_s3_uris: [ @source_uri, "s3://test-bucket/other.pdf" ])
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "false"
    assert_nil build_route(question: question)
  end

  class SequencedRagService
    attr_reader :calls

    def initialize(batches)
      @batches = batches
      @calls = []
    end

    def retrieve_chunks(question, **kwargs)
      @calls << { question: question, **kwargs }
      { chunks: @batches.fetch(@calls.size - 1, @batches.last), retrieval_trace: {} }
    end
  end

  def assert_pinned_designator_call(call)
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, call[:number_of_results]
    assert_equal [ @source_uri ], call[:entity_s3_uris]
    assert_equal true, call[:force_entity_filter]
    assert_equal [ "document" ], call[:entity_sources]
  end

  def assert_applicability_contract(prompt)
    assert_includes prompt, "identity_unknown_reference"
    assert_includes prompt, "UNKNOWN EQUIPMENT IDENTITY"
    assert_includes prompt, "does not prove that a procedure applies"
    assert_includes prompt, "terminal assignment"
    assert_includes prompt, "applicability to the current job is not confirmed"
    assert_includes prompt, "observational check"
    assert_includes prompt, "does not confirm equipment identity"
    assert prompt.index("identity_unknown_reference") < prompt.index("Cite every supported technical claim")
  end

  def capture_structured_events
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    output.string.lines.filter_map do |line|
      JSON.parse(line.split("[PILOT_USAGE] ", 2).last) if line.include?("[PILOT_USAGE]")
    end
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  def build_route(question: "¿Qué indica el LED ABC12?", entity_s3_uris: [ @source_uri ],
                  entity_sources: [ "document" ], output_channel: :web, rag_service: nil,
                  generator: nil, expander: nil, episode: nil, raw_question: nil)
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
      expander: expander,
      episode: episode,
      raw_question: raw_question
    )
  end

  # Everything but the two things that legitimately differ between two runs:
  # wall-clock timings and the per-instance correlation id.
  def comparable_result(result)
    timings = result.dig(:retrieval_trace, :structured_route)
      .to_h
      .except(:retrieval_ms, :expansion_ms, :local_ms, :generation_ms)

    result.except(:retrieval_trace, :correlation_id, :retrieve_ms, :generation_ms).merge(structured_route: timings)
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

  def designator_chunk(page, content)
    synthetic_chunk(content, rank: page, sha: "page-#{page}").merge(
      metadata: {
        "canonical_name" => "Montacargas Hidráulico Modelo MH",
        "original_source_uri" => @source_uri,
        "page_number" => page
      }
    )
  end

  def terminal_sheet(row)
    "## Borneras\n| N° Terminal | Designación |\n|---|---|\n#{row}\n"
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

  # SPM is a different series on each of these three boards; two of them share
  # section_identity "SISTEL", so only the heading tells them apart.
  def spm_board_chunks
    [
      board_chunk(
        content: "## S7 — DIAGRAM: CARLOS SILVA TPR50 — Cadena de Seguridades\n" \
                 "SPM | SERIE PUERTAS CABINA - EXTERIORES",
        page: 9,
        section_identity: "CARLOS SILVA",
        sha: "spm-tpr50"
      ),
      board_chunk(
        content: "## S7 — DIAGRAM: TWISTER TW - INAPELSA — Diagrama de conexiones\n" \
                 "SPM | SERIE DE PUERTAS",
        page: 88,
        section_identity: "SISTEL",
        sha: "spm-twister"
      ),
      board_chunk(
        content: "## DELTA + — Diagrama de Cadena de Seguridad\nSPM | SERIE PUERTAS DE PISO",
        page: 91,
        section_identity: "SISTEL",
        sha: "spm-delta"
      )
    ]
  end

  def dl2_board_chunks
    [
      board_chunk(
        content: "## LEVEL CONTROL 1B – ELECTRICO - PREMONTADA\nDL2 | SERIE CERROJOS CERRADA",
        page: 3,
        section_identity: "ALJO",
        sha: "dl2-aljo"
      ),
      board_chunk(
        content: "## KDT 11 — Diagrama de Series\nDL2 | SERIE PUERTAS EXTERIORES - CABINA",
        page: 13,
        section_identity: "CARLOS SILVA",
        sha: "dl2-kdt"
      )
    ]
  end

  def arca_board_chunks
    [
      board_chunk(
        content: "## Diagrama de Cadena de Seguridades — Placa ARCA\n" \
                 "P32 | SERIE CERROJOS CABINA -EXTERIORES",
        page: 61, section_identity: "ORONA", sha: "arca"
      ),
      board_chunk(
        content: "## ARCA BASICO — Tabla de Series\nP32 | SERIE CERROJOS CABINA - EXTERIORES",
        page: 62, section_identity: "ORONA", sha: "arca-basico"
      ),
      board_chunk(
        content: "## S7 — DIAGRAM: ARCA II Safety Chain & Connector Layout\n" \
                 "P32 | SERIE CERROJOS EXTERIORES - CABINA",
        page: 63, section_identity: "ORONA", sha: "arca2"
      ),
      board_chunk(
        content: "## S4 — SAFETY SYSTEM: Diagrama de cadena de seguridades ARCA III\n" \
                 "P32 | SERIE SEGURIDADES PRINCIPALES",
        page: 64, section_identity: "ORONA", sha: "arca3"
      )
    ]
  end

  def board_chunk(content:, page:, section_identity:, sha:)
    {
      content: content,
      metadata: {
        "canonical_name" => "SEGURIDADES 1.1-1.pdf",
        "original_source_uri" => @source_uri,
        "page_number" => page,
        "section_identity" => section_identity
      },
      location_uri: "s3://test-bucket/chunks/chunk_p#{page}.txt",
      chunk_sha256: sha,
      rank: page
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
