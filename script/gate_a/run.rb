# frozen_string_literal: true

# Gate A driver: runs PdfLayoutExtractor (Fase 2) + TopologyEdgeDeriver (Fase 3)
# over every page of SEGURIDADES 1.1-1.pdf and dumps per-page geometry, edges
# and — for pages that emit nothing — the reason the chain was rejected.
#
#   bin/rails runner script/gate_a/run.rb
#
# Output: tmp/gate_a_measurement.json

PDF_PATH = ENV.fetch(
  "GATE_A_PDF",
  "/Users/lahirisan/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf"
)
OUT_PATH = ENV.fetch("GATE_A_OUT", "tmp/gate_a_measurement.json")

# Mirrors TopologyEdgeDeriver#edge_for, but records WHY each chain died.
class DiagnosticDeriver
  def initialize(layout)
    @deriver = TopologyEdgeDeriver.new(layout)
  end

  def call
    chains = @deriver.send(:chains)
    reasons = Hash.new(0)
    edges = []

    chains.each do |chain|
      reason, edge = classify(chain)
      reasons[reason] += 1
      edges << edge if edge
    end

    {
      segments:  @deriver.send(:segments).size,
      labels:    @deriver.send(:labels).size,
      chains:    chains.size,
      reasons:   reasons,
      raw_edges: edges,
      edges:     @deriver.derive
    }
  end

  private

  def classify(chain)
    d = @deriver
    head_point = d.send(:point_at, chain[:head])
    tail_point = d.send(:point_at, chain[:tail])
    return [ :t_junction, nil ] unless d.send(:dead_end?, head_point, chain[:ids])
    return [ :t_junction, nil ] unless d.send(:dead_end?, tail_point, chain[:ids])

    head = label_state(head_point, chain)
    tail = label_state(tail_point, chain)

    return [ :no_label_at_terminal, nil ] if head[:reason] == :none || tail[:reason] == :none
    return [ :two_labels_ambiguous, nil ] if head[:reason] == :many || tail[:reason] == :many
    return [ :label_passed_by, nil ]      if head[:reason] == :passed || tail[:reason] == :passed
    return [ :rotated_label, nil ]        if head[:reason] == :rotated || tail[:reason] == :rotated
    return [ :not_a_name, nil ]           if head[:reason] == :unnameable || tail[:reason] == :unnameable
    return [ :raster_rival, nil ]         if head[:reason] == :outranked || tail[:reason] == :outranked
    return [ :same_label_loop, nil ]      if head[:label].text == tail[:label].text

    [ :emitted, d.send(:build_edge, chain, [ head_point, head[:label] ], [ tail_point, tail[:label] ]) ]
  end

  # Splits sole_label_at's nil into its distinguishable causes. `rotated` and
  # `outranked` are Fase 3b's two guards (I-14); the order here mirrors
  # sole_label_at, so the funnel keeps adding up.
  def label_state(point, chain)
    d = @deriver
    labels = d.send(:labels)
    in_range = labels.select { |l| d.send(:chebyshev_gap, point, l.bbox) <= TopologyEdgeDeriver::TERMINAL_TOLERANCE_PT }
    return { reason: :none } if in_range.empty?

    terminating = in_range.reject { |l| d.send(:passes_by?, chain, l) }
    return { reason: :passed } if terminating.empty?
    return { reason: :many } if terminating.size > 1

    label = terminating.first
    return { reason: :rotated } if label.rotated
    return { reason: :unnameable } unless d.send(:nameable?, label)
    return { reason: :outranked } if d.send(:outranked_on_an_image?, point, label)

    { reason: :ok, label: label }
  end
end

binary = File.binread(PDF_PATH)
splitter = PdfPageSplitterService.new(binary)
pages = []

splitter.each_page do |page_number, page_binary|
  layout = PdfLayoutExtractor.extract(page_binary, page_number: page_number)
  diag = DiagnosticDeriver.new(layout).call

  words = layout[:words]
  images = Array(layout[:images])

  pages << {
    page:             page_number,
    segments:         diag[:segments],
    raw_lines:        layout[:lines].size,
    rects:            layout[:rects].size,
    words:            words.size,
    labels:           diag[:labels],
    images:           images.size,
    small_images:     images.count { |i| i[:size_class] == :small },
    text_chars:       layout[:text_layer_chars],
    image_area_ratio: layout[:image_area_ratio].round(3),
    chains:           diag[:chains],
    reasons:          diag[:reasons],
    edge_count:       diag[:edges].size,
    edges:            diag[:edges].map { |e| e.slice(:from, :to, :evidence, :chain) },
    word_texts:       words.map { |w| { text: w[:text], bbox: w[:bbox].map { |v| v.round(1) } } }
  }
  warn("page #{page_number}: #{diag[:edges].size} edges, #{diag[:chains]} chains, #{diag[:segments]} segs")
end

File.write(OUT_PATH, JSON.pretty_generate({ pdf: PDF_PATH, pages: pages }))
warn("wrote #{OUT_PATH} — #{pages.sum { |p| p[:edge_count] }} edges over #{pages.size} pages")
