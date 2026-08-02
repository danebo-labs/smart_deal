require "test_helper"

class VisionTopologyExtractorTest < ActiveSupport::TestCase
  FIXTURE_PATH = Rails.root.join("test/fixtures/files/pdf_layout_extractor_sample.pdf")
  MEDIA_BOX    = [ 0, 0, 600, 400 ].freeze

  setup do
    @page_binary = split_pages(File.binread(FIXTURE_PATH)).first
  end

  # ---------------------------------------------------------------- the flag ---

  test "with the flag off nothing is rendered, nothing is called and nothing is returned" do
    called = false
    result = with_vision_flag(false) do
      derive(layout: relational_layout, client: fake_client(connections: [ full_connection ]) { called = true })
    end

    assert_equal [], result.edges
    assert_equal 0, result.crop_count
    assert_not called, "no vision call may be billed with the flag off"
  end

  # ------------------------------------------------- the Gate B degradation ---

  # docs/rag/gate_b_calibracion_vision.md: T2's relations measured 88.2 %
  # precision (95 % lower bound 81.6 %) against the 85 % the gate required, so
  # the tier ships reading components and stating no relation.
  test "with the tier on and relations at their default, T2 returns components and no edge" do
    result = with_vision_flag(true, relations: false) do
      derive(
        layout: relational_layout,
        client: fake_client(
          connections: [ full_connection ],
          components:  [ { "label" => "SOBRECARGA", "canonical_component" => "Celula de carga MICELECT",
                           "evidence" => "rotulo MWR-4" } ]
        )
      )
    end

    assert_equal [], result.edges, "the Gate B default must not let a vision relation reach a chunk"
    assert_equal 1, result.components.size
    assert result.input_tokens.positive?, "the page is still read — only the relations are dropped"
  end

  # Fase 5b. Off by default because it raises the cost per page by roughly half
  # and its effect on precision is a hypothesis, not a number.
  test "zoom tiles are absent by default and reach the prompt when switched on" do
    without = capture_user_content { derive(layout: relational_layout, client: fake_client) }
    with    = with_zoom_tiles { capture_user_content { derive(layout: relational_layout, client: fake_client) } }

    assert_equal 0, count_zoom_blocks(without)
    assert_equal PdfPageRasterizer::ZOOM_COLUMNS * PdfPageRasterizer::ZOOM_ROWS, count_zoom_blocks(with)
  end

  test "the relations switch re-enables vision edges without touching the tier flag" do
    result = with_vision_flag(true, relations: true) do
      derive(layout: relational_layout, client: fake_client(connections: [ full_connection ]))
    end

    assert_equal 1, result.edges.size
    assert_equal :vision, result.edges.first[:method]
  end

  # -------------------------------------------------------------- eligibility ---

  test "the Fase 1 triage verdict alone makes a page eligible" do
    assert VisionTopologyExtractor.eligible?(layout: bare_layout, triage: { has_visual_relations: true })
    assert VisionTopologyExtractor.eligible?(layout: bare_layout, triage: { visual_complexity: :high })
    assert VisionTopologyExtractor.eligible?(layout: bare_layout, triage: { "visual_complexity" => "high" })

    assert_not VisionTopologyExtractor.eligible?(layout: bare_layout, triage: { visual_complexity: :moderate })
    assert_not VisionTopologyExtractor.eligible?(layout: bare_layout, triage: nil)
  end

  # The cover page of the reference document has no text layer at all (I-20), so
  # T1 cannot resolve one endpoint on it and T2 is the only engine.
  test "a page with no usable text layer is eligible regardless of geometry" do
    layout = bare_layout.merge(text_layer_chars: 12)

    assert VisionTopologyExtractor.eligible?(layout: layout)
  end

  test "the geometric criterion is the router's own census criterion" do
    assert VisionTopologyExtractor.eligible?(layout: relational_layout)
    assert_equal FileMultimodalRouter::LONG_SEGMENT_MIN_COUNT, VisionTopologyExtractor::MIN_LONG_SEGMENTS
    assert_equal FileMultimodalRouter::SMALL_IMAGE_MIN_COUNT, VisionTopologyExtractor::MIN_SMALL_IMAGES

    assert_not VisionTopologyExtractor.eligible?(
      layout: relational_layout.merge(lines: segments(VisionTopologyExtractor::MIN_LONG_SEGMENTS - 1))
    )
    assert_not VisionTopologyExtractor.eligible?(
      layout: relational_layout.merge(images: small_images(VisionTopologyExtractor::MIN_SMALL_IMAGES - 1))
    )
  end

  test "an ineligible page is never rendered and never billed" do
    called = false
    result = with_vision_flag(true) do
      derive(layout: bare_layout.merge(text_layer_chars: 5_000), client: fake_client(connections: []) { called = true })
    end

    assert_equal [], result.edges
    assert_not called
  end

  # -------------------------------------------------------------------- crops ---

  test "each crop is framed with the label that names its graphic" do
    captured = nil
    with_vision_flag(true) do
      derive(layout: relational_layout, client: fake_client(connections: []) { |content| captured = content })
    end

    labels = captured.filter_map { |block| block[:text] }
                     .grep(/\ACROP /)
                     .map { |text| text.split("adjacent to this graphic: ").last }

    assert_equal [ "LIMITADOR", "CONECTOR AI" ], labels
    assert_equal 2, captured.count { |block| block[:type] == "image" } - 1, "one image per crop, plus the full page"
  end

  test "a graphic no printed label names is not cropped" do
    layout = relational_layout.merge(words: [], images: small_images(VisionTopologyExtractor::MIN_SMALL_IMAGES))

    result = with_vision_flag(true) { derive(layout: layout, client: fake_client(connections: [])) }

    assert_equal 0, result.crop_count, "a graphic no label is near has no anchor to send with it"
  end

  # ------------------------------------------------------ output = contract v8 ---

  test "a documented_connection becomes a v8 edge with method vision" do
    result = with_vision_flag(true) do
      derive(layout: relational_layout, client: fake_client(connections: [ full_connection ]))
    end

    assert_equal 1, result.edges.size
    edge = result.edges.first
    assert_equal "CERROJOS CABINA", edge[:from]
    assert_equal "32", edge[:to]
    assert_equal :vision, edge[:method]
    assert_includes edge[:evidence], "conductor amarillo"
    assert_equal %i[from to method evidence].sort, edge.keys.sort
  end

  # The plan's Definición de terminado: with neither a text layer nor a vector to
  # trace — where T1 is structurally silent — the tier still produces output.
  test "a page with no text layer and no vectors still produces an edge" do
    layout = { page_number: 9, media_box: MEDIA_BOX, words: [], lines: [], rects: [], images: [],
               text_layer_chars: 0, image_area_ratio: 1.0 }

    result = with_vision_flag(true) do
      derive(layout: layout, client: fake_client(connections: [ full_connection ]))
    end

    assert_equal 0, result.crop_count, "no small image means no crop"
    assert_equal [ :vision ], result.edges.pluck(:method)
  end

  test "a terminal number is a legitimate endpoint even though it has no letter" do
    result = with_vision_flag(true) do
      derive(layout: relational_layout,
             client: fake_client(connections: [ connection("185", "184", "puente impreso entre bornes 185 y 184") ]))
    end

    assert_equal [ [ "185", "184" ] ], result.edges.map { |edge| [ edge[:from], edge[:to] ] }
  end

  # -------------------------------------------------------------- rejections ---

  test "rejects endpoints and evidence that cannot be cited" do
    rejected = [
      connection("", "32", "un conductor amarillo va del borne al dispositivo"),
      connection("CERROJOS", "CERROJOS", "un conductor amarillo une los dos extremos"),
      connection("CN37   C   N   2   5", "32", "una fila de nombres de conector con el espaciado de Fase 2"),
      connection("CN37 C N 25 CN33 C34", "32", "la misma fila transcrita con espacios normales"),
      connection("(NO)", "32", "la anotacion de estado de contacto junto al aparato"),
      connection("A" * (VisionTopologyExtractor::MAX_ENDPOINT_CHARACTERS + 1), "32", "un nombre imposiblemente largo"),
      connection("CERROJOS CABINA", "32", "cable"),
      "not an object"
    ]

    result = with_vision_flag(true) { derive(layout: relational_layout, client: fake_client(connections: rejected)) }

    assert_equal [], result.edges
  end

  test "the same pair read from two wires is one edge" do
    connections = [
      full_connection,
      connection("32", "CERROJOS CABINA", "el mismo par leido del segundo conductor amarillo")
    ]

    result = with_vision_flag(true) { derive(layout: relational_layout, client: fake_client(connections: connections)) }

    assert_equal 1, result.edges.size
  end

  # Provisional conflict policy of Fase 5, to be fixed by Gate B: T1 wins, T2
  # contributes only what T1 does not cover.
  test "a pair T1 already traced is dropped, in either order and any case" do
    traced = [ { from: "LIMITADOR", to: "CONECTOR AI", method: :leader_line, evidence: "polilínea …" } ]
    connections = [
      connection("conector ai", "limitador", "el mismo par que la geometria ya probo en esta pagina"),
      full_connection
    ]

    result = with_vision_flag(true) do
      derive(layout: relational_layout, traced_edges: traced, client: fake_client(connections: connections))
    end

    assert_equal [ [ "CERROJOS CABINA", "32" ] ], result.edges.map { |edge| [ edge[:from], edge[:to] ] }
  end

  test "a page cannot contribute more than MAX_EDGES_PER_PAGE edges" do
    connections = (1..(VisionTopologyExtractor::MAX_EDGES_PER_PAGE + 5)).map do |index|
      connection("DISPOSITIVO #{index}", "#{index}", "un conductor visible une el dispositivo #{index} con su borne")
    end

    result = with_vision_flag(true) { derive(layout: relational_layout, client: fake_client(connections: connections)) }

    assert_equal VisionTopologyExtractor::MAX_EDGES_PER_PAGE, result.edges.size
  end

  # ------------------------------------------------------------ failure modes ---

  test "a truncated response contributes no edges at all" do
    client = fake_client(connections: [ full_connection ], stop_reason: "max_tokens")
    result = with_vision_flag(true) { derive(layout: relational_layout, client: client) }

    assert_equal [], result.edges, "a cut-off relation list is unverifiable, not partially usable"
  end

  test "unparseable JSON and a raising client degrade the page instead of failing it" do
    assert_equal [], with_vision_flag(true) {
      derive(layout: relational_layout, client: fake_client(raw_text: "I cannot read this page."))
    }.edges

    raising = Object.new
    raising.define_singleton_method(:call) { |**| raise ClaudeChunkingClient::ApiError, "boom" }

    assert_equal [], with_vision_flag(true) { derive(layout: relational_layout, client: raising) }.edges
  end

  test "components are sanitized and deduplicated" do
    components = [
      { "label" => "SOBRECARGA", "canonical_component" => "Celula de carga MICELECT", "evidence" => "rotulo MWR-4" },
      { "label" => "sobrecarga", "canonical_component" => "celula de carga micelect", "evidence" => "duplicado" },
      { "label" => "", "canonical_component" => "sin etiqueta", "evidence" => "x" },
      { "label" => "STOP FOSO", "canonical_component" => "", "evidence" => "x" }
    ]

    result = with_vision_flag(true) do
      derive(layout: relational_layout, client: fake_client(connections: [], components: components))
    end

    assert_equal [ "SOBRECARGA" ], result.components.pluck(:label)
  end

  test "the locale reaches the prompt so vision evidence is written in the page's language" do
    captured = nil
    with_vision_flag(true) do
      derive(layout: relational_layout, locale: "es",
             client: fake_client(connections: []) { |content| captured = content })
    end

    assert_includes captured.last[:text], "Evidence language: es."
  end

  test "the call is billed on its own vision_tier route with the multimodal model" do
    captured = {}
    client = fake_client(connections: []) { |_content, kwargs| captured = kwargs }

    with_vision_flag(true) { derive(layout: relational_layout, client: client) }

    assert_equal "vision_tier", captured[:route]
    assert_equal "vision_tier", captured[:tracking_prefix]
    assert_equal BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS, captured[:max_tokens]
    assert_equal "ingest:abc:p17", captured[:correlation_id]
  end

  private

  def derive(layout:, client:, traced_edges: [], triage: nil, locale: nil)
    VisionTopologyExtractor.derive(
      @page_binary,
      layout: layout, page_number: 17, total_pages: 98, filename: "SEGURIDADES.pdf",
      triage: triage, traced_edges: traced_edges, locale: locale, client: client,
      correlation_id: "ingest:abc:p17"
    )
  end

  # `relations:` defaults to the tier flag so every test written before the Gate
  # B verdict keeps exercising the sanitizer. Production's default is the other
  # one — relations off — and the two tests above pin it explicitly.
  def with_vision_flag(enabled, relations: enabled)
    original  = ENV.fetch("INGESTION_VISION_TIER_ENABLED", nil)
    original2 = ENV.fetch("INGESTION_VISION_TIER_RELATIONS_ENABLED", nil)
    ENV["INGESTION_VISION_TIER_ENABLED"] = enabled ? "true" : nil
    ENV["INGESTION_VISION_TIER_RELATIONS_ENABLED"] = relations ? "true" : nil
    yield
  ensure
    restore_env("INGESTION_VISION_TIER_ENABLED", original)
    restore_env("INGESTION_VISION_TIER_RELATIONS_ENABLED", original2)
  end

  def restore_env(name, value)
    value.nil? ? ENV.delete(name) : ENV[name] = value
  end

  def with_zoom_tiles
    original = ENV.fetch("INGESTION_VISION_TIER_ZOOM_TILES", nil)
    ENV["INGESTION_VISION_TIER_ZOOM_TILES"] = "true"
    yield
  ensure
    restore_env("INGESTION_VISION_TIER_ZOOM_TILES", original)
  end

  def capture_user_content
    captured = nil
    with_vision_flag(true) do
      client = fake_client { |user_content, _| captured = user_content }
      VisionTopologyExtractor.derive(
        @page_binary, layout: relational_layout, page_number: 17, total_pages: 98,
        filename: "SEGURIDADES.pdf", client: client
      )
    end
    captured
  end

  def count_zoom_blocks(user_content)
    Array(user_content).count { |block| block[:type] == "text" && block[:text].to_s.start_with?("ZOOM ") }
  end

  # Mimics ClaudeChunkingClient#call closely enough to exercise the whole parse
  # path: same keyword surface, same { text:, usage:, model:, stop_reason: } shape.
  def fake_client(connections: [], components: [], stop_reason: nil, raw_text: nil, &probe)
    text = raw_text || JSON.generate(
      "documented_connections" => connections,
      "documented_components"  => components,
      "anti_hallucination_notes" => "todo leido directamente"
    )
    client = Object.new
    client.define_singleton_method(:call) do |user_content:, **kwargs|
      probe&.call(user_content, kwargs)
      {
        text:        text,
        usage:       OpenStruct.new(input_tokens: 4_200, output_tokens: 310),
        model:       BatchChunkingPrompt::MODEL_MULTIMODAL,
        stop_reason: stop_reason
      }
    end
    client
  end

  def full_connection
    connection("CERROJOS CABINA", "32", "conductor amarillo desde CERROJOS CABINA hasta el borne 32 de la regleta")
  end

  def connection(from, to, evidence)
    { "from" => from, "to" => to, "evidence" => evidence }
  end

  def bare_layout
    { page_number: 17, media_box: MEDIA_BOX, words: [], lines: [], rects: [], images: [],
      text_layer_chars: 1_800, image_area_ratio: 0.3 }
  end

  # A relational content page: enough segments and small images to pass the
  # census criterion, two small graphics each named by a printed label 4 pt away,
  # and a third one no label is near — the measured mix (81.7 % of the reference
  # document's small images resolve to a label, not all of them).
  def relational_layout
    bare_layout.merge(
      lines:  segments(VisionTopologyExtractor::MIN_LONG_SEGMENTS),
      words:  [ word("LIMITADOR", [ 100, 152, 180, 164 ]), word("CONECTOR AI", [ 300, 252, 400, 264 ]) ],
      images: [
        small_image("XO1", [ 100, 100, 160, 148 ]),
        small_image("XO2", [ 300, 200, 360, 248 ]),
        small_image("XO3", [ 500, 50, 560, 98 ])
      ]
    )
  end

  def segments(count)
    Array.new(count) { |index| { from: [ 10.0, 10.0 + index ], to: [ 90.0, 10.0 + index ] } }
  end

  def small_images(count)
    Array.new(count) { |index| small_image("XO#{index}", [ 10 + (index * 70), 100, 60 + (index * 70), 148 ]) }
  end

  def small_image(name, bbox)
    { name: name, width: 105, height: 183, bbox: bbox, size_class: :small }
  end

  def word(text, bbox)
    { text: text, bbox: bbox }
  end

  def split_pages(binary)
    pages = []
    PdfPageSplitterService.new(binary).each_page { |_num, page_binary| pages << page_binary }
    pages
  end
end
