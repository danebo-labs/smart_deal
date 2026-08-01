require "test_helper"

# The `seguridades_layouts` fixture is real `PdfLayoutExtractor.extract` output
# for pages 2, 3, 17, 32 and 63 of `SEGURIDADES 1.1-1.pdf` — the document the
# plan is built around — captured verbatim, one page per line. Regenerate with:
#
#   PdfPageSplitterService.new(File.binread(pdf)).each_page do |n, page|
#     layouts[n.to_s] = PdfLayoutExtractor.extract(page, page_number: n)
#   end
#
# Page 3 is the plan's primary fixture and its ground truth is Apéndice D of
# docs/rag/plan_conocimiento_visual.md. Pages 17, 32 and 63 are three other
# sections, reviewed by eye against the rendered page while this class was
# written; page 2 is a section divider.
class TopologyEdgeDeriverTest < ActiveSupport::TestCase
  LAYOUTS = JSON.parse(
    Rails.root.join("test/fixtures/files/topology_edge_deriver_seguridades_layouts.json").read,
    symbolize_names: true
  ).freeze

  # --------------------------------------------------- page 3 vs Apéndice D ---

  test "page 3 resolves exactly the two edges its geometry supports, and no others" do
    edges = TopologyEdgeDeriver.derive(LAYOUTS[:"3"])

    assert_equal [ [ "FINALES", "CONECTOR AI" ], [ "LIMITADOR", "CONECTOR AI" ] ],
                 edges.map { |edge| [ edge[:from], edge[:to] ] }
  end

  test "page 3 reports the polyline and the labelled endpoints it was resolved from" do
    edge = TopologyEdgeDeriver.derive(LAYOUTS[:"3"]).find { |e| e[:from] == "LIMITADOR" }

    assert_equal :leader_line, edge[:method]
    assert_equal [ [ 485.6, 154.9 ], [ 405.2, 154.1 ], [ 405.8, 248.1 ] ], edge[:chain]
    assert_equal "polilínea (485.6,154.9)->(405.2,154.1)->(405.8,248.1) " \
                 "une LIMITADOR (x 504-541, y 154-161) con CONECTOR AI (x 316-382, y 231-240)",
                 edge[:evidence]
  end

  # Apéndice D, fixture case #1: human reading put ACUÑAMIENTO on BOTH connectors
  # and proximity in x puts it on AG alone. Outcome (c) — no edge — is one of the
  # three the plan accepts, and it is reached on evidence: the only drawn line
  # anywhere near that label PASSES it (x=639.4, running the full height from
  # y=21.7 to y=154.5, 6.4 pt clear of the label's right edge) and terminates
  # nowhere near it. Proximity in x is never consulted, so it cannot decide.
  test "page 3 emits nothing for ACUÑAMIENTO instead of picking a connector by proximity" do
    edges = TopologyEdgeDeriver.derive(LAYOUTS[:"3"])

    assert_empty edges.select { |edge| [ edge[:from], edge[:to] ].include?("ACUÑAMIENTO") }

    acunamiento = LAYOUTS[:"3"][:words].find { |word| word[:text].strip == "ACUÑAMIENTO" }
    assert acunamiento.present?, "the label itself must be present — the edge is absent for lack of a terminus"

    nearest = LAYOUTS[:"3"][:lines].flat_map { |line| [ line[:from], line[:to] ] }.map do |x, y|
      [ [ acunamiento[:bbox][0] - x, 0, x - acunamiento[:bbox][2] ].max,
        [ acunamiento[:bbox][1] - y, 0, y - acunamiento[:bbox][3] ].max ].max
    end.min
    assert_operator nearest, :>, TopologyEdgeDeriver::TERMINAL_TOLERANCE_PT,
      "no segment endpoint is within tolerance of ACUÑAMIENTO; if one appears, this case changed"
  end

  # The loops are the dominant leader-line shape on page 3: a wire leaves one
  # terminal of CONECTOR AI, passes through a component photo and returns to
  # another terminal of the SAME connector. Both ends resolve to the same label,
  # and the component in the middle is named by neither, so nothing is emitted.
  test "page 3 emits no self-edge for the loops that leave and re-enter CONECTOR AI" do
    edges = TopologyEdgeDeriver.derive(LAYOUTS[:"3"])

    assert_empty edges.select { |edge| edge[:from] == edge[:to] }
  end

  # ------------------------------------------------------------ other pages ---

  test "page 63 resolves the lamp-to-connector run, naming a stacked label verbatim" do
    edges = TopologyEdgeDeriver.derive(LAYOUTS[:"63"])

    assert_equal [ [ "ALUMBRADO CABINA", "J12" ] ], edges.map { |edge| [ edge[:from], edge[:to] ] }
    assert_equal 4, edges.first[:chain].size
  end

  # Both pages are dense with leader lines and both are correctly silent: on 17
  # the terminal rail is a raster image, so the block's numbers are not printed
  # text and no terminal can resolve; on 32 the only chain whose ends both fall
  # near labels is the CN7 → OBSTACULO wire, and its left end is rejected because
  # the wire runs 5.2 pt under the printed FOTOCELULA it would otherwise claim.
  test "pages 17 and 32 resolve nothing rather than guessing at unlabelled targets" do
    assert_empty TopologyEdgeDeriver.derive(LAYOUTS[:"17"])
    assert_empty TopologyEdgeDeriver.derive(LAYOUTS[:"32"])
  end

  test "a section divider page returns [] without raising" do
    assert_equal [], TopologyEdgeDeriver.derive(LAYOUTS[:"2"])
  end

  test "an empty or absent layout returns [] without raising" do
    assert_equal [], TopologyEdgeDeriver.derive({})
    assert_equal [], TopologyEdgeDeriver.derive(nil)
    assert_equal [], TopologyEdgeDeriver.derive(page_layout(words: [], lines: []))
  end

  test "deriving twice returns the same edges, so a re-ingest is idempotent" do
    assert_equal TopologyEdgeDeriver.derive(LAYOUTS[:"3"]), TopologyEdgeDeriver.derive(LAYOUTS[:"3"])
  end

  test "every emitted edge is a leader_line; column_proximity is not implemented" do
    methods = LAYOUTS.values.flat_map { |layout| TopologyEdgeDeriver.derive(layout) }.pluck(:method)

    assert methods.any?
    assert_equal [ :leader_line ], methods.uniq
  end

  # ------------------------------------------------------------------ guards --

  # Control for every rejection below: an elbow that ends clear of LIMITADOR at
  # one end and clear of CONECTOR AI at the other, i.e. page 3's brown cable.
  test "the control geometry does resolve, so the rejections below are the guard and not the setup" do
    edges = TopologyEdgeDeriver.derive(control_layout)

    assert_equal [ [ "LIMITADOR", "CONECTOR AI" ] ], edges.map { |edge| [ edge[:from], edge[:to] ] }
  end

  test "a chain longer than four segments resolves to zero edges" do
    layout = page_layout(
      words: control_words,
      lines: [
        segment(486, 155, 455, 155),
        segment(455.5, 154, 455.5, 120),
        segment(456, 119, 430, 119),
        segment(429, 118.5, 429, 180),
        segment(429.5, 181, 406, 248)
      ]
    )

    assert_equal 5, layout[:lines].size
    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  test "a branching junction resolves to zero edges instead of picking an arm" do
    layout = page_layout(words: control_words, lines: control_lines + [ segment(404, 156, 404, 100) ])

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  test "a terminal with two labels in range resolves to zero edges" do
    layout = page_layout(
      words: control_words + [ printed_word("POLEA", 500, 128, 530, 138) ],
      lines: control_lines
    )

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  test "a terminal that lands on another segment's interior is a T-junction, not a dead end" do
    layout = page_layout(words: control_words, lines: control_lines + [ segment(486, 100, 486, 200) ])

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  test "a chain that starts and ends at the same label resolves to zero edges" do
    layout = page_layout(
      words: control_words,
      lines: [ segment(486, 155, 450, 155), segment(450, 156.2, 450, 168), segment(451, 168, 486, 168) ]
    )

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  # Replays the measured page-32 trap: a wire from connector CN7 to the OBSTACULO
  # device ends 14 pt from the printed FOTOCELULA — near enough to resolve — but
  # runs 5.2 pt underneath it. The label describes the route, not the terminus.
  test "a chain that runs under a label may not claim it" do
    layout = page_layout(
      words: [ printed_word("FOTOCELULA", 709, 106, 761, 114), printed_word("OBSTACULO", 862, 112, 909, 119) ],
      lines: [ segment(695, 101, 907, 101) ]
    )

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  test "a terminal-number row, a merged row of names and a bare annotation are not names" do
    [ "4  5  6  7  8  9  10 11 1 2", "C1 C 2  C3  C4  C5  C6", "(NO)" ].each do |unusable|
      layout = page_layout(
        words: [ printed_word(unusable, 504, 154, 541, 161), printed_word("CONECTOR AI", 316, 231, 382, 240) ],
        lines: control_lines
      )

      assert_equal [], TopologyEdgeDeriver.derive(layout), "#{unusable.inspect} must not name an edge endpoint"
    end
  end

  test "an unusable label still counts for ambiguity, so it cannot uncover a second one" do
    layout = page_layout(
      words: control_words + [ printed_word("(NO)", 500, 132, 530, 140) ],
      lines: control_lines
    )

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  # Apéndice D's verbatim: the PDF prints `STOP FOSO` as two stacked lines, and
  # Fase 2 hands them over as two `words` entries (I-08). Fase 8 matches on the
  # printed string, so the edge has to carry it whole.
  test "a label printed on two stacked lines is named verbatim, not by the line the chain reached" do
    layout = page_layout(
      words: [
        printed_word("STOP", 462, 18, 482, 26),
        printed_word("FOSO", 462, 9, 482, 16),
        printed_word("CN1", 295, 155, 325, 168)
      ],
      lines: [ segment(500, 20, 500, 150), segment(499, 151, 345, 151) ]
    )

    assert_equal [ [ "STOP FOSO", "CN1" ] ],
                 TopologyEdgeDeriver.derive(layout).map { |edge| [ edge[:from], edge[:to] ] }
  end

  # Same geometry as above with a drawn rule between the two rows: they are now
  # a table, not one label, so the terminal sees two labels 2 pt apart instead of
  # one and the edge is dropped as ambiguous. Without this, page 17's table rows
  # (3.2 pt apart) merge into `PS2V… PS2VH ….`.
  test "words separated by a drawn rule are table rows, not one stacked label" do
    layout = page_layout(
      words: [
        printed_word("STOP", 462, 18, 482, 26),
        printed_word("FOSO", 462, 9, 482, 16),
        printed_word("CN1", 295, 155, 325, 168)
      ],
      lines: [ segment(500, 20, 500, 150), segment(499, 151, 345, 151) ],
      rects: [ { bbox: [ 440, 17.0, 500, 40 ] } ]
    )

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  # ------------------------------------------------------------ integration --

  test "the whole known-bad page resolves to zero edges" do
    assert_equal [], TopologyEdgeDeriver.derive(known_bad_layout)
  end

  test "nothing in production code invokes the deriver yet" do
    invocation = /TopologyEdgeDeriver\.(derive|new)\b/

    callers = Dir.glob(Rails.root.join("app/**/*.rb").to_s).select do |path|
      next false if path.end_with?("topology_edge_deriver.rb")

      File.readlines(path).any? { |source_line| !source_line.match?(/\A\s*#/) && source_line.match?(invocation) }
    end

    assert_empty callers, "TopologyEdgeDeriver must not be called from production code yet: #{callers}"
  end

  private

  def page_layout(words:, lines:, rects: [])
    {
      page_number: 1, media_box: [ 0, 0, 960, 540 ],
      words: words, lines: lines, rects: rects,
      images: [], text_layer_chars: 0, image_area_ratio: 0.0
    }
  end

  def printed_word(text, x0, y0, x1, y1)
    { text: text, bbox: [ x0.to_f, y0.to_f, x1.to_f, y1.to_f ] }
  end

  def segment(x0, y0, x1, y1)
    { from: [ x0.to_f, y0.to_f ], to: [ x1.to_f, y1.to_f ] }
  end

  def control_words
    [ printed_word("LIMITADOR", 504, 154, 541, 161), printed_word("CONECTOR AI", 316, 231, 382, 240) ]
  end

  def control_lines
    [ segment(486, 155, 405, 155), segment(405.5, 153.8, 406, 248) ]
  end

  def control_layout
    page_layout(words: control_words, lines: control_lines)
  end

  # One page carrying every rejection at once: a five-segment chain, a branch, a
  # loop back to its own label, a terminal on another segment's interior, a
  # chain running under the label it would claim, and a terminal-number row.
  def known_bad_layout
    page_layout(
      words: [
        printed_word("LIMITADOR", 504, 154, 541, 161),
        printed_word("CONECTOR AI", 316, 231, 382, 240),
        printed_word("FOTOCELULA", 709, 106, 761, 114),
        printed_word("OBSTACULO", 862, 112, 909, 119),
        printed_word("1  2  3  4  5  6", 100, 300, 180, 310)
      ],
      lines: [
        # five segments from LIMITADOR up to CONECTOR AI
        segment(486, 155, 455, 155), segment(455.5, 154, 455.5, 120), segment(456, 119, 430, 119),
        segment(429, 118.5, 429, 180), segment(429.5, 181, 406, 248),
        # a branch off the first joint
        segment(454, 156, 454, 90),
        # a loop that leaves and returns to LIMITADOR
        segment(560, 155, 600, 155), segment(600, 156.2, 600, 168), segment(599, 168, 560, 168),
        # the wire that runs under FOTOCELULA
        segment(695, 101, 907, 101),
        # a terminal-number row reached by a clean two-segment elbow
        segment(200, 290, 200, 340), segment(199, 341, 150, 341)
      ]
    )
  end
end
