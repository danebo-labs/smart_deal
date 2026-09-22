# frozen_string_literal: true

require "test_helper"

class Rag::ContextEvidenceRouteTest < ActiveSupport::TestCase
  THYSSEN = "En Thyssen-E, ¿qué LED señala una condición normal y cuál un fallo?"
  SPRINGS = "Cómo se ajustan los resortes de la fijación de cables ?"
  FUJI = "#{SPRINGS}\nes Fuji Yida"
  LCB = "Según los pasos de instalación física de la página 2 del procedimiento Otis de cambio de la placa LCB I por la LCB II, luego de colocar la LCB II alineando los orificios, ¿qué se debe usar como plantilla (gabarito) para marcar los nuevos orificios en la base?"

  class FakeRagService
    attr_reader :calls

    def initialize(chunks)
      @chunks = chunks
      @calls = []
    end

    def retrieve_chunks(question, **kwargs)
      @calls << { question: question, **kwargs }
      { chunks: @chunks, retrieval_trace: {} }
    end
  end

  class RaisingRagService
    def retrieve_chunks(*)
      raise BedrockRagService::BedrockServiceError, "retrieve down"
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
    def neighbor_chunk(divider_chunk:, target_page:)
      nil
    end
  end

  setup do
    @account = accounts(:legacy)
    @original_gs = ENV.fetch("RAG_GROUNDED_SYNTHESIS_ENABLED", nil)
    ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
  end

  teardown do
    if @original_gs.nil?
      ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
    else
      ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = @original_gs
    end
  end

  test "search text is the short projection and the LCB question stays off this route" do
    assert_equal "THYSSEN-E SERIE E LED", Rag::ContextProjection.search_text(THYSSEN)
    assert_equal "resortes fijación ajustar", Rag::ContextProjection.search_text(SPRINGS)
    assert_equal "Fuji Yida resortes fijación ajustar", Rag::ContextProjection.search_text(FUJI)
    assert_not Rag::ContextProjection.applicable?(LCB)
    assert_nil build_route(question: LCB)
    assert_nil build_route(output_channel: :whatsapp)
    assert_nil build_route(entity_s3_uris: [ "s3://bucket/pinned.pdf" ])
    assert_nil build_route(output_channel: nil)
  end

  test "keeps the serie e diagram and drops the variador and a thyssen page that is not serie e" do
    assert Rag::ContextChunkFilter.keep?(THYSSEN, serie_e_chunk)
    assert_not Rag::ContextChunkFilter.keep?(THYSSEN, variador_chunk)
    assert_not Rag::ContextChunkFilter.keep?(THYSSEN, serie_f_chunk)
  end

  test "keeps the internal note and drops cable pages that do not print the spring" do
    assert Rag::ContextChunkFilter.keep?(SPRINGS, note_chunk)
    assert Rag::ContextChunkFilter.keep?(FUJI, note_chunk)
    assert_not Rag::ContextChunkFilter.keep?(SPRINGS, cable_page_chunk)
    assert_not Rag::ContextChunkFilter.keep?(FUJI, cable_page_chunk)
    assert_not Rag::ContextChunkFilter.keep?(FUJI, traveling_cable_chunk)
    assert_not Rag::ContextChunkFilter.keep?(FUJI, spring_without_both_brands_chunk)
  end

  test "retrieves the projection once and generates with the original question" do
    rag = FakeRagService.new([ variador_chunk, serie_e_chunk, serie_f_chunk ])
    generator = FakeGenerator.new("L9 supervisa la serie principal. El documento no define el encendido. [1]")
    route = build_route(rag_service: rag, generator: generator)

    outcome = route.execute

    assert_equal :answered, outcome.status
    assert_equal 1, rag.calls.size
    assert_equal "THYSSEN-E SERIE E LED", rag.calls.first[:question]
    assert_equal RagRetrievalProfile::OPEN_RESULTS, rag.calls.first[:number_of_results]
    assert_equal [], rag.calls.first[:entity_s3_uris]
    assert_equal false, rag.calls.first[:force_entity_filter]
    assert_equal 1, generator.calls.size
    prompt = generator.calls.first[:prompt]
    assert_includes prompt, THYSSEN
    assert_includes prompt, "SERIE SEGURIDADES PRINCIPALES"
    assert_not_includes prompt, "TCM VARIADOR"
    assert_not_includes prompt, "DISPLAY LCD"
  end

  test "abstains without a generation when the body filter keeps nothing" do
    rag = FakeRagService.new([ variador_chunk ])
    generator = FakeGenerator.new("no debe llamarse")
    outcome = build_route(rag_service: rag, generator: generator).execute

    assert_equal :abstained, outcome.status
    assert_empty generator.calls
  end

  test "a failed retrieve stays unavailable and does not generate" do
    generator = FakeGenerator.new("no debe llamarse")
    outcome = build_route(rag_service: RaisingRagService.new, generator: generator).execute

    assert_equal :unavailable, outcome.status
    assert_nil outcome.result
    assert_empty generator.calls
  end

  private

  def build_route(question: THYSSEN, output_channel: :web, entity_s3_uris: [], rag_service: nil, generator: nil)
    Rag::ContextEvidenceRoute.build(
      question: question,
      account: @account,
      entity_s3_uris: entity_s3_uris,
      entity_sources: [],
      response_locale: :es,
      output_channel: output_channel,
      rag_service: rag_service || FakeRagService.new([]),
      generator: generator || FakeGenerator.new("sin usar"),
      expander: FakeExpander.new
    )
  end

  def chunk(content, section:, page:, sha:)
    {
      content: content,
      metadata: {
        "canonical_name" => "Manual",
        "original_source_uri" => "s3://test-bucket/manual.pdf",
        "page_number" => page,
        "section_identity" => section
      },
      original_source_uri: "s3://test-bucket/manual.pdf",
      location_uri: "s3://test-bucket/chunks/#{sha}.txt",
      chunk_sha256: sha,
      rank: 1
    }
  end

  def serie_e_chunk
    chunk(
      <<~TEXT,
        [DOCUMENT: SEGURIDADES 1.1-1.pdf]
        [SEARCH_ALIASES: THYSSEN, THYSSEN-E, SERIE E, L9 L8 L7]
        ## S7 — DIAGRAM: SERIE E — Cadena de Seguridades Principales
        | L9  | SERIE SEGURIDADES PRINCIPALES |
        | L8  | SERIE PUERTAS EXTERIORES |
        | L7  | SERIE CERROJOS EXTERIORES - CABINA |
      TEXT
      section: "THYSSEN",
      page: 93,
      sha: "chunk-91"
    )
  end

  def variador_chunk
    chunk(
      <<~TEXT,
        [DOCUMENT: r.pdf]
        [SEARCH_ALIASES: THYSSEN BOETTICHER, MWI, ESA]
        TCM VARIADOR
        MWI ERROR CALCULADOR
      TEXT
      section: "THYSSEN BOETTICHER",
      page: 2,
      sha: "r-p2"
    )
  end

  def serie_f_chunk
    chunk(
      <<~TEXT,
        [DOCUMENT: THYSSEN SERIE F HIDRAULICO.pdf]
        [SEARCH_ALIASES: THYSSEN, DISPLAY LCD]
        ## DISPLAY LCD
        CANALETA CON MAZOS
      TEXT
      section: "THYSSEN",
      page: 32,
      sha: "serie-f"
    )
  end

  def note_chunk
    chunk(
      <<~TEXT,
        [DOCUMENT: nota_tecnica_interna_amarre_cables_rev0.md]
        [SEARCH_ALIASES: enchufe cuña, rope terminal springs]
        ## Nota
        NOTA TÉCNICA INTERNA
        El resorte de la fijación en fuji yida no se transfiere.
      TEXT
      section: nil,
      page: nil,
      sha: "note"
    )
  end

  def cable_page_chunk
    chunk(
      <<~TEXT,
        [DOCUMENT: manual en castellano yida.pdf]
        [SEARCH_ALIASES: Fuji Yida, enchufe]
        ## Instalación
        fuji yida: aflojar el enchufe para instalar el cable.
      TEXT
      section: nil,
      page: 45,
      sha: "p45"
    )
  end

  def traveling_cable_chunk
    chunk(
      <<~TEXT,
        [DOCUMENT: Manual(new)-FUJI YIDA.pdf]
        [SEARCH_ALIASES: Fuji Yida]
        ## Traveling cable
        fuji yida traveling cable wedge sockets.
      TEXT
      section: nil,
      page: 60,
      sha: "p60"
    )
  end

  def spring_without_both_brands_chunk
    chunk(
      "## Ajuste\nfuji: el resorte de la fijación.\n",
      section: nil,
      page: 12,
      sha: "fuji-only"
    )
  end
end
