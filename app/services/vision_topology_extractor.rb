# frozen_string_literal: true

# T2, the vision tier of docs/rag/plan_conocimiento_visual.md (Fase 5): reads the
# relations a page DRAWS and the identity of the small parts it photographs, for
# the pages where T1 has nothing to trace.
#
# WHY THIS TIER EXISTS (measured, Gate A / I-15 / I-20 / I-26)
#
# T1 (PdfLayoutExtractor + TopologyEdgeDeriver) emits 19 edges over 18 of the 98
# pages of `SEGURIDADES 1.1-1.pdf`. All 19 are correct — and 80 pages get
# nothing. The dominant reason is not a weak algorithm: 42.5 % of T1's
# rejections, dominant on 32 pages, are terminals whose printed name lives
# INSIDE the raster of the terminal strip, where a text layer cannot reach. Page
# 17 has ~15 relations with an explicit terminal number and T1 emits `[]`. T2 is
# the only possible engine on 61 content pages, and the largest coverage lever in
# the plan.
#
# WHAT IT PRODUCES
#
# The same contract v8 records T1 produces, with `method: :vision` instead of
# `method: :leader_line` — so ChunkMergerService, BatchResultsParserService,
# retrieval and generation never learn a second shape. Provenance stays
# distinguishable in the chunk body (`DERIVATION: vision`), which is what
# app/prompts/bedrock/generation.txt and AnswerSafetyProcessor (Fase 6a/6b) key
# their stricter citation rule on.
#
# WHICH INGESTION ROUTE (decided here, I-34)
#
# The SYNCHRONOUS route only: SingleFileChunkingService (`pdf_mixed`) →
# ChunkMergerService → BatchResultsParserService. Two reasons, both structural:
# T2 needs the page binary at the moment it renders, and the async Batch route
# (ManualBatchIngestionService → IngestManualBatchResultsJob) has already run
# `page.cleanup` by the time a result comes back; and the sync route is the one
# Fase 4 threaded `topology_edges` through end to end (I-31), so a vision edge
# reaches a chunk body with no new plumbing. Nothing here is coupled to that
# route, though: `.derive` takes a page binary and returns edges, which is
# exactly what Fase 7's option (a) needs to give the shadow ingest both tiers
# without building the persistence layer I-31 left ownerless.
#
# NEVER AT RUNTIME (docs/RAG_SEGURIDADES_BENCHMARK.md:109-115).
class VisionTopologyExtractor
  class ExtractionError < StandardError; end

  # One Opus vision call, so eligibility is a budget decision as much as a
  # capability one. The geometric criterion is the Apéndice C census criterion
  # the Fase 1 router already uses — same numbers, same source, no second
  # threshold to keep true. `layout[:lines]` is already free of the <=20 pt noise
  # the router's own probe filters out, so the two counts are comparable.
  MIN_LONG_SEGMENTS = FileMultimodalRouter::LONG_SEGMENT_MIN_COUNT
  MIN_SMALL_IMAGES  = FileMultimodalRouter::SMALL_IMAGE_MIN_COUNT

  # Same cut `FileMultimodalRouter#route_page` uses for "this page has no usable
  # text layer": there T1 cannot resolve a single endpoint, so T2 is the only
  # engine and runs regardless of geometry (the cover page of this document has
  # no text layer at all — I-20).
  TEXT_LAYER_MIN_CHARS = 100

  # Measured over the 98 pages: 1,646 small images, 1,345 of which resolve to an
  # adjacent printed label; per page that is p50 15, p90 24, max 33. 40 is a
  # runaway guard, not a policy — it never binds on this document, and when it
  # does bind it is logged, never silent.
  MAX_CROPS_PER_PAGE = 40

  # Page 17, the densest measured page, draws ~15 relations (I-15). 24 leaves
  # 1.6x headroom and still bounds a page whose answer runs away.
  MAX_EDGES_PER_PAGE = 24

  # Endpoint hygiene, T1's rejections (`nameable?`) carried over with two
  # deliberate differences, both because the failure looks different when a model
  # transcribes text than when glyph grouping merges it:
  #
  #   * "must contain a letter" is NOT reused. `32`, `185`, `74` are exactly the
  #     terminal numbers this tier exists to read (I-15) and they are printed
  #     digits;
  #   * MERGED_ROW_MARKER (two or more spaces) is what a whole row of connector
  #     names looks like in Fase 2's output. A model asked to transcribe returns
  #     that row with ordinary single spaces, so the marker alone would never
  #     fire — MAX_ENDPOINT_WORDS is the same rejection in the shape T2 produces
  #     it. The longest endpoint name in the Gate A ground truth is 3 words
  #     (`PESTLLOS TECHO CABINA`, `CERROJOS EMBARQUE 1`); 5 leaves headroom.
  MAX_ENDPOINT_CHARACTERS = TopologyEdgeDeriver::MAX_LABEL_CHARACTERS
  MAX_ENDPOINT_WORDS      = 5
  MERGED_ROW_MARKER       = /\s{2,}/
  ANNOTATION_ONLY         = /\A\(.*\)\z/

  # An `evidence` string is what a technician sees quoted for this claim, and
  # what Gate B reads to judge it. T1's shortest real evidence is ~90 characters;
  # 20 rejects "wire", "drawn line" and other non-evidence without prescribing
  # how the model should write.
  MIN_EVIDENCE_CHARACTERS = 20

  MAX_COMPONENT_NAME_CHARACTERS = 80

  Result = Struct.new(:edges, :components, :crop_count, :input_tokens, :output_tokens, keyword_init: true) do
    def self.empty
      new(edges: [], components: [], crop_count: 0, input_tokens: 0, output_tokens: 0)
    end
  end

  # @param page_binary  [String]  raw single-page PDF bytes
  # @param layout       [Hash]    this page's PdfLayoutExtractor result (Fase 2)
  # @param page_number  [Integer]
  # @param total_pages  [Integer]
  # @param filename     [String]
  # @param triage       [Hash, nil] the Fase 1 verdict for this page
  #   (`visual_complexity`, `has_visual_relations`, `component_count`); absent
  #   whenever IngestionVisualTriageFlag is off, which the geometric criterion
  #   below covers
  # @param traced_edges [Array<Hash>] T1's edges for this page. Used ONLY to drop
  #   pairs T1 already proved (T1 wins — provisional until Gate B fixes the
  #   conflict policy). Never shown to the model: Gate B measures T2 against
  #   these, and a model handed the answer key measures nothing
  # @param locale       [String, nil] ISO 639-1 for the `evidence` prose. Measured
  #   in I-34: without it the model writes English evidence for a Spanish page,
  #   which would sit in the same chunk body as T1's Spanish evidence
  # @return [Result]
  def self.derive(page_binary, layout:, page_number:, total_pages:, filename:,
                  triage: nil, traced_edges: [], locale: nil, client: nil, correlation_id: nil)
    new(
      page_binary, layout: layout, page_number: page_number, total_pages: total_pages,
      filename: filename, triage: triage, traced_edges: traced_edges, locale: locale,
      client: client, correlation_id: correlation_id
    ).derive
  end

  # True when this page is worth one vision call. Public so the eligibility rule
  # can be measured (Gate B) without paying for a call.
  def self.eligible?(layout:, triage: nil)
    new(nil, layout: layout, page_number: nil, total_pages: nil, filename: nil, triage: triage).eligible?
  end

  def initialize(page_binary, layout:, page_number:, total_pages:, filename:,
                 triage: nil, traced_edges: [], locale: nil, client: nil, correlation_id: nil)
    @page_binary    = page_binary
    @layout         = layout || {}
    @page_number    = page_number
    @total_pages    = total_pages
    @filename       = filename
    @triage         = (triage || {}).symbolize_keys
    @traced_edges   = Array(traced_edges)
    @locale         = locale
    @client         = client
    @correlation_id = correlation_id
    @rejections     = Hash.new(0)
  end

  def derive
    return Result.empty unless IngestionVisionFlag.enabled?
    return Result.empty if @page_binary.blank?

    unless eligible?
      Rails.logger.info("VisionTopologyExtractor: p#{@page_number} skipped (not eligible)")
      return Result.empty
    end

    render_and_extract
  rescue StandardError => e
    # A tier that cannot read a page must not fail the page. The chunk still gets
    # its narrative and its model field_records; it just gets no vision edge.
    Rails.logger.warn("VisionTopologyExtractor: p#{@page_number} failed (#{e.class}) — #{e.message}")
    Result.empty
  end

  def eligible?
    return true if @triage[:has_visual_relations] == true
    return true if @triage[:visual_complexity].to_s == "high"
    return true if @layout[:text_layer_chars].to_i < TEXT_LAYER_MIN_CHARS

    Array(@layout[:lines]).size >= MIN_LONG_SEGMENTS && small_images.size >= MIN_SMALL_IMAGES
  end

  private

  def render_and_extract
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rasterizer = PdfPageRasterizer.new(@page_binary, media_box: @layout[:media_box])
    page       = rasterizer.page
    crops      = build_crops(rasterizer)

    response = call_model(page, crops)
    parsed   = parse_response(response)
    edges    = sanitize_connections(parsed["documented_connections"])

    log_page_metrics(
      page: page, crops: crops, response: response, parsed: parsed, edges: edges,
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    )

    Result.new(
      edges:         edges,
      components:    sanitize_components(parsed["documented_components"]),
      crop_count:    crops.size,
      input_tokens:  token(response[:usage], :input_tokens),
      output_tokens: token(response[:usage], :output_tokens)
    )
  end

  # One crop per small graphic that a printed label names, framed with that
  # label (TopologyEdgeDeriver.label_for_image, the forward reading of the
  # raster-rival rule of Fase 3b/I-20). A graphic no label names is not cropped:
  # the model could describe it but nothing could cite it.
  def build_crops(rasterizer)
    candidates = small_images.filter_map do |image|
      label = TopologyEdgeDeriver.label_for_image(@layout, image[:bbox])
      next unless label

      { image: image, label: label }
    end

    if candidates.size > MAX_CROPS_PER_PAGE
      Rails.logger.warn(
        "VisionTopologyExtractor: p#{@page_number} has #{candidates.size} labelled small images — " \
        "cropping the first #{MAX_CROPS_PER_PAGE}, #{candidates.size - MAX_CROPS_PER_PAGE} dropped"
      )
      candidates = candidates.first(MAX_CROPS_PER_PAGE)
    end

    candidates.filter_map do |candidate|
      raster = rasterizer.crop(
        PdfPageRasterizer.union_bbox(candidate[:image][:bbox], candidate[:label][:bbox])
      )
      next unless raster

      { raster: raster, label: candidate[:label][:text] }
    end
  end

  def small_images
    @small_images ||= Array(@layout[:images]).select do |image|
      image[:size_class] == :small && Array(image[:bbox]).size == 4
    end
  end

  def call_model(page, crops)
    client.call(
      user_content: VisionTopologyPrompt.user_content(
        page: page, crops: crops, page_number: @page_number,
        total_pages: @total_pages, filename: @filename, locale: @locale
      ),
      filename:        @filename,
      page_number:     @page_number,
      total_pages:     @total_pages,
      max_tokens:      BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
      tracking_prefix: "vision_tier",
      correlation_id:  @correlation_id,
      route:           "vision_tier"
    )
  end

  def client
    @client ||= ClaudeChunkingClient.new(
      model:  BatchChunkingPrompt::MODEL_MULTIMODAL,
      system: VisionTopologyPrompt::SYSTEM_BLOCKS
    )
  end

  # A truncated relation list is not a short relation list: the cut can land
  # mid-object, and no rung of a retry ladder makes an unverifiable answer
  # verifiable. The page keeps its narrative and loses its vision edges.
  def parse_response(response)
    raise ExtractionError, "vision response truncated at max_tokens" if response[:stop_reason] == "max_tokens"

    parsed = LlmJsonParser.parse(response[:text].to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError => e
    raise ExtractionError, "unparseable vision JSON: #{e.message}"
  end

  # Every rule here is a rejection. A cited connection that is not drawn on the
  # page is the worst failure this system can produce, and unlike T1 there is no
  # geometry to fall back on — the guards ARE the safety of this tier.
  def sanitize_connections(raw)
    edges = Array(raw).filter_map { |entry| edge_for(entry) }
                      .uniq { |edge| [ edge[:from], edge[:to] ].sort }

    edges = drop_traced(edges)

    if edges.size > MAX_EDGES_PER_PAGE
      Rails.logger.warn(
        "VisionTopologyExtractor: p#{@page_number} returned #{edges.size} vision edges — " \
        "keeping #{MAX_EDGES_PER_PAGE}, #{edges.size - MAX_EDGES_PER_PAGE} dropped"
      )
      @rejections[:over_page_cap] += edges.size - MAX_EDGES_PER_PAGE
      edges = edges.first(MAX_EDGES_PER_PAGE)
    end

    edges
  end

  def edge_for(entry)
    return reject(:not_an_object) unless entry.is_a?(Hash)

    values = entry.deep_stringify_keys
    from   = normalize(values["from"])
    to     = normalize(values["to"])
    proof  = normalize(values["evidence"])

    return reject(:blank_endpoint) if from.blank? || to.blank?
    return reject(:unusable_endpoint) unless endpoint?(from, values["from"]) && endpoint?(to, values["to"])
    return reject(:same_endpoint) if from.casecmp(to).zero?
    return reject(:no_evidence) if proof.length < MIN_EVIDENCE_CHARACTERS

    { from: from, to: to, method: :vision, evidence: proof }
  end

  def endpoint?(text, raw)
    return false if text.length > MAX_ENDPOINT_CHARACTERS
    return false if text.split(" ").size > MAX_ENDPOINT_WORDS
    return false if raw.to_s.match?(MERGED_ROW_MARKER)
    return false if text.match?(ANNOTATION_ONLY)

    text.match?(/[[:alnum:]]/)
  end

  # Provisional conflict policy, to be fixed by Gate B: T1 wins. Where geometry
  # already proved a pair, the deterministic edge with its measured evidence
  # stays and the vision reading of the same pair is dropped — T2 contributes
  # only what T1 does not cover.
  def drop_traced(edges)
    traced = @traced_edges.filter_map do |edge|
      from = normalize(edge[:from] || edge["from"])
      to   = normalize(edge[:to] || edge["to"])
      next if from.blank? || to.blank?

      [ from.downcase, to.downcase ].sort
    end

    return edges if traced.empty?

    edges.reject do |edge|
      next false unless traced.include?([ edge[:from].downcase, edge[:to].downcase ].sort)

      @rejections[:already_traced_by_t1] += 1
      true
    end
  end

  def sanitize_components(raw)
    Array(raw).filter_map do |entry|
      next unless entry.is_a?(Hash)

      values = entry.deep_stringify_keys
      label  = normalize(values["label"])
      name   = normalize(values["canonical_component"])
      proof  = normalize(values["evidence"])
      next if label.blank? || name.blank?
      next if label.length > MAX_ENDPOINT_CHARACTERS || name.length > MAX_COMPONENT_NAME_CHARACTERS

      { label: label, canonical_component: name, evidence: proof }
    end.uniq { |component| [ component[:label].downcase, component[:canonical_component].downcase ] }
  end

  def reject(reason)
    @rejections[reason] += 1
    nil
  end

  def normalize(value)
    value.to_s.gsub(/\s+/, " ").strip
  end

  def token(usage, name)
    usage.respond_to?(name) ? usage.public_send(name).to_i : 0
  end

  # The measurement Gate B is required to report ("coste por página medido, no
  # estimado") plus the rejection funnel that says WHY a page produced what it
  # produced — the same shape of evidence Gate A's funnel gave for T1.
  def log_page_metrics(page:, crops:, response:, parsed:, edges:, duration_ms:)
    Rails.logger.info(
      JSON.generate(
        event:              "vision_topology_page",
        filename:           @filename,
        page_number:        @page_number,
        model:              response[:model],
        prompt_contract:    VisionTopologyPrompt::CONTRACT_VERSION,
        prompt_fingerprint: VisionTopologyPrompt.prompt_fingerprint_sha256,
        page_px:            "#{page.width}x#{page.height}",
        page_dpi:           page.dpi,
        page_bytes:         page.bytes,
        crops:              crops.size,
        crop_bytes:         crops.sum { |crop| crop[:raster].bytes },
        input_tokens:       token(response[:usage], :input_tokens),
        output_tokens:      token(response[:usage], :output_tokens),
        connections_raw:    Array(parsed["documented_connections"]).size,
        edges_kept:         edges.size,
        components:         Array(parsed["documented_components"]).size,
        rejections:         @rejections.to_h,
        duration_ms:        duration_ms
      )
    )
  rescue StandardError => e
    Rails.logger.warn("VisionTopologyExtractor: failed to log page metrics — #{e.message}")
  end
end
