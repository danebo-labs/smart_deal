require "test_helper"

# The `seguridades_layouts` fixture is real `PdfLayoutExtractor.extract` output
# for pages 2, 3, 17, 32, 56, 61, 63, 67 and 97 of `SEGURIDADES 1.1-1.pdf` — the
# document the plan is built around — captured verbatim, one page per line.
# Regenerate with:
#
#   PdfPageSplitterService.new(File.binread(pdf)).each_page do |n, page|
#     layouts[n.to_s] = PdfLayoutExtractor.extract(page, page_number: n)
#   end
#
# Page 3 is the plan's primary fixture and its ground truth is Apéndice D of
# docs/rag/plan_conocimiento_visual.md. Pages 17, 32 and 63 are three other
# sections, reviewed by eye against the rendered page while this class was
# written; page 2 is a section divider. Pages 56, 61, 67 and 97 are the four
# edges the Gate A measurement found to be false (gate_a_medicion_topologia.md
# §4.2 and §4.3) and Fase 3b removes.
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

  # ------------------------------------ Gate A's four false edges (Fase 3b) ---
  #
  # Each of the four is asserted twice: once that the edge is gone, and once on
  # the printed geometry that made it wrong, so a page emptied later for some
  # unrelated reason does not pass for a fix.

  # Gate A §4.3. The magenta wire is a jumper between two connectors: it leaves
  # terminal `+24` of CC1 and ends on CC2. CC1's terminal numbering is drawn
  # inside the photo of the strip, so the only printed text within tolerance of
  # that end was `PISO SUPERIOR` — which belongs to the red cable running to the
  # display — and `PISO SUPERIOR -> CC2` was emitted for a connection nothing
  # draws anywhere on the page.
  test "page 56 emits no edge for the CC1 jumper whose real terminal name is rasterised" do
    assert_equal [], TopologyEdgeDeriver.derive(LAYOUTS[:"56"])
  end

  test "page 56: the strip that end lands inside is named CC1, and CC1 is closer to it" do
    image = smallest_image_containing(LAYOUTS[:"56"], [ 551.5, 165.9 ])
    assert image, "the terminal has to land inside an image, or something other than the guard emptied this page"

    strip_name = nearest_word_gap(LAYOUTS[:"56"], image) { |word| word[:text].strip == "CC1" }
    cited      = nearest_word_gap(LAYOUTS[:"56"], image) { |word| %w[PISO SUPERIOR].include?(word[:text].strip) }

    assert_in_delta 13.18, strip_name, 0.01
    assert_in_delta 18.23, cited, 0.01
    assert_operator strip_name, :<, cited
  end

  # Gate A §4.3. The wire ends on terminal `C1` of CN32, which is raster; the
  # nearest printed text is `PESTLLOS TECHO CABINA`, 14.1 pt away and part of a
  # different group of the drawing. Two real devices, no wire between them.
  test "page 97 emits no edge between the two devices no wire joins" do
    assert_equal [], TopologyEdgeDeriver.derive(LAYOUTS[:"97"])
  end

  test "page 97: two connector-name rows overlap that strip; the cited device does not" do
    image = smallest_image_containing(LAYOUTS[:"97"], [ 746.2, 194.9 ])
    assert image, "the terminal has to land inside an image, or something other than the guard emptied this page"

    connector_rows = nearest_word_gap(LAYOUTS[:"97"], image) { |word| word[:text].strip.start_with?("CN") }
    cited = nearest_word_gap(LAYOUTS[:"97"], image) do |word|
      word[:text].include?("TECHO CABINA") || word[:text].strip == "PESTLLOS"
    end

    assert_in_delta 0.0, connector_rows, 0.01
    assert_in_delta 6.56, cited, 0.01
    assert_operator connector_rows, :<, cited
  end

  # Gate A §4.2 measured `CERRADURAS EXTERIORES -> B` here, where the printed
  # terminal is `P35B` and only its last glyph survived. Fase 2b's bbox fix
  # moved the false edge rather than removing it — with correct boxes the page
  # emitted `TENSORA -> A 8 2 P`, the vertical terminal `P28A` read the wrong
  # way up. Fase 2 marks those glyphs `rotated: true` (I-13/I-19) precisely
  # because their text is not in reading order, and this guard is what stops
  # them naming anything.
  test "page 61 emits no edge naming a vertical terminal marking" do
    assert_equal [], TopologyEdgeDeriver.derive(LAYOUTS[:"61"])
  end

  test "page 61: the words at that terminal are rotated, so none of them may be quoted" do
    stack = LAYOUTS[:"61"][:words].select do |word|
      word[:bbox][0].between?(725.0, 740.0) && word[:bbox][1].between?(305.0, 330.0)
    end

    assert_equal %w[A 8 2 P], stack.map { |word| word[:text].strip }
    assert stack.all? { |word| word[:rotated] }, "Fase 2 must mark all four glyphs rotated"
  end

  # Gate A §4.2. The printed terminal 2 of `P3` reads `ES`; grouping by
  # descending y reversed it and `PUERTAS EXTE. -> SE` was emitted — the
  # relation is real, the name is written backwards.
  #
  # Measured honestly: this page was already empty before Fase 3b. With Fase
  # 2b's corrected box, the wire runs THROUGH the grown box of `SE` and the
  # run-past guard rejects it first. So the assertion below is a backstop, not
  # a demonstration — what makes the abstention principled rather than lucky is
  # that the name could not have been cited even had the wire ended clear of it.
  test "page 67 emits no edge naming a reversed terminal" do
    assert_equal [], TopologyEdgeDeriver.derive(LAYOUTS[:"67"])
  end

  test "page 67: the name at that terminal is the rotated, reversed `SE`, so it is unquotable" do
    reversed = LAYOUTS[:"67"][:words].find { |word| word[:text].strip == "SE" }

    assert reversed, "the reversed reading of the printed `ES` must still be in words"
    assert reversed[:rotated]
  end

  test "no edge on any fixture page is named by a rotated word" do
    LAYOUTS.each do |page, layout|
      rotated = layout[:words].select { |word| word[:rotated] }.map { |word| word[:text].strip }
      next if rotated.empty?

      TopologyEdgeDeriver.derive(layout).each do |edge|
        [ edge[:from], edge[:to] ].each do |name|
          assert_not_includes rotated, name, "page #{page} cited the rotated word #{name.inspect}"
        end
      end
    end
  end

  # -------------------------- the correct edges most exposed to the guard -----
  #
  # Both of these end ON a graphic with the printed name beside it, which is the
  # shape the guard rejects on pages 56 and 97. They survive because the label
  # names that same graphic, and that is measured here rather than assumed.

  test "page 3 keeps LIMITADOR ↔ CONECTOR AI: the wire ends on the photo LIMITADOR names" do
    edges = TopologyEdgeDeriver.derive(LAYOUTS[:"3"])
    assert_includes edges.map { |edge| [ edge[:from], edge[:to] ] }, [ "LIMITADOR", "CONECTOR AI" ]

    image = smallest_image_containing(LAYOUTS[:"3"], [ 485.6, 154.9 ])
    assert image, "if the terminal stops landing inside an image this case no longer covers the guard"

    cited = nearest_word_gap(LAYOUTS[:"3"], image) { |word| word[:text].strip == "LIMITADOR" }
    rival = nearest_word_gap(LAYOUTS[:"3"], image) { |word| word[:text].strip != "LIMITADOR" }

    assert_in_delta 0.0, cited, 0.01, "the label overlaps the photo it names"
    assert_in_delta 11.37, rival, 0.01
    assert_operator cited, :<=, rival
  end

  test "page 63 keeps ALUMBRADO CABINA ↔ J12: J12 is the nearest upright name to its strip" do
    edges = TopologyEdgeDeriver.derive(LAYOUTS[:"63"])
    assert_equal [ [ "ALUMBRADO CABINA", "J12" ] ], edges.map { |edge| [ edge[:from], edge[:to] ] }

    image = smallest_image_containing(LAYOUTS[:"63"], [ 753.8, 413.5 ])
    assert image, "if the terminal stops landing inside an image this case no longer covers the guard"

    cited = nearest_word_gap(LAYOUTS[:"63"], image) { |word| word[:text].strip == "J12" }
    rival = nearest_word_gap(LAYOUTS[:"63"], image) do |word|
      !word[:rotated] && word[:text].strip != "J12"
    end
    markings = nearest_word_gap(LAYOUTS[:"63"], image) { |word| word[:rotated] }

    assert_in_delta 16.03, cited, 0.01
    assert_in_delta 45.79, rival, 0.01
    assert_operator cited, :<, rival
    assert_operator markings, :<, cited,
      "the strip's own rotated markings are closer than J12 — excluding them is what keeps this edge"
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

  # ---------------------------------------------- raster rivals (Fase 3b) ----
  #
  # The control resolves LIMITADOR ↔ CONECTOR AI with the LIMITADOR terminal at
  # (486,155). Drawing a photo around that terminal is what turns the guard on.

  test "an image around the terminal changes nothing while the cited label is the nearest name to it" do
    layout = page_layout(words: control_words, lines: control_lines, images: [ image(450, 130, 500, 180) ])

    assert_equal [ [ "LIMITADOR", "CONECTOR AI" ] ],
                 TopologyEdgeDeriver.derive(layout).map { |edge| [ edge[:from], edge[:to] ] }
  end

  test "a terminal inside an image may not be named by a label another name sits closer to" do
    layout = page_layout(
      words: control_words + [ printed_word("CC1", 460, 181, 480, 189) ],
      lines: control_lines,
      images: [ image(450, 130, 500, 180) ]
    )

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  # The rival above sits 1 pt from the photo and 26 pt from the terminal, so it
  # is out of TERMINAL_TOLERANCE_PT and the uniqueness rule never sees it. That
  # is the whole point: it is the rival the old guard could not consult.
  test "the closer name is out of terminal tolerance, so uniqueness alone would still emit" do
    layout = page_layout(
      words: control_words + [ printed_word("CC1", 460, 181, 480, 189) ],
      lines: control_lines
    )

    assert_equal [ [ "LIMITADOR", "CONECTOR AI" ] ],
                 TopologyEdgeDeriver.derive(layout).map { |edge| [ edge[:from], edge[:to] ] }
  end

  # Page 39 prints `CERROJOS EXTERIORES` twice, above and below the same photo,
  # 1.14 pt and 4.22 pt from it. A second printing of the SAME name cannot make
  # the citation wrong, so it is not a rival.
  test "a second printing of the same name does not outrank the label it repeats" do
    layout = page_layout(
      words: control_words + [ printed_word("LIMITADOR", 460, 181, 480, 189) ],
      lines: control_lines,
      images: [ image(450, 130, 500, 180) ]
    )

    assert_equal [ [ "LIMITADOR", "CONECTOR AI" ] ],
                 TopologyEdgeDeriver.derive(layout).map { |edge| [ edge[:from], edge[:to] ] }
  end

  # I-07: Fase 2 reports bbox nil for an XObject declared in Resources but never
  # painted. No position, no opinion.
  test "an image with no known position neither raises nor rejects" do
    layout = page_layout(
      words: control_words, lines: control_lines,
      images: [ { name: "Unpainted", width: 64, height: 64, bbox: nil, size_class: :small } ]
    )

    assert_equal [ [ "LIMITADOR", "CONECTOR AI" ] ],
                 TopologyEdgeDeriver.derive(layout).map { |edge| [ edge[:from], edge[:to] ] }
  end

  # --------------------------------------------- rotated labels (Fase 3b) ----

  test "a rotated label never names a terminal" do
    layout = page_layout(
      words: [ printed_word("LIMITADOR", 504, 154, 541, 161), rotated_word("B", 370, 231, 394, 240) ],
      lines: control_lines
    )

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  test "the same geometry with the name printed upright does resolve" do
    layout = page_layout(
      words: [ printed_word("LIMITADOR", 504, 154, 541, 161), printed_word("P35B", 370, 231, 394, 240) ],
      lines: control_lines
    )

    assert_equal [ [ "LIMITADOR", "P35B" ] ],
                 TopologyEdgeDeriver.derive(layout).map { |edge| [ edge[:from], edge[:to] ] }
  end

  test "a rotated label in range still counts for ambiguity instead of uncovering the next one" do
    layout = page_layout(words: control_words + [ rotated_word("B", 370, 231, 394, 240) ], lines: control_lines)

    assert_equal [], TopologyEdgeDeriver.derive(layout)
  end

  # A turned glyph under an upright label is a terminal marking beside it, not
  # its second line. If the two stacked, the upright name would inherit both the
  # marking's text and its `rotated` flag, and the edge would be lost.
  test "a rotated word under an upright label does not stack into it" do
    layout = page_layout(
      words: control_words + [ rotated_word("P", 533, 145, 541, 152) ],
      lines: control_lines
    )

    assert_equal [ [ "LIMITADOR", "CONECTOR AI" ] ],
                 TopologyEdgeDeriver.derive(layout).map { |edge| [ edge[:from], edge[:to] ] }
  end

  # ------------------------------------------------------------ integration --

  test "the whole known-bad page resolves to zero edges" do
    assert_equal [], TopologyEdgeDeriver.derive(known_bad_layout)
  end

  # ⚠️ Fase 4 (contract v8) is precisely the phase that wires this deriver into
  # production, behind IngestionLayoutFlag (off by default) — see
  # docs/rag/plan_conocimiento_visual.md. Pre-Fase-4 this asserted an empty
  # list; now it pins the exact two legitimate callers so any OTHER new
  # caller still fails loudly.
  test "only the Fase 4 ingestion callers invoke the deriver" do
    invocation = /TopologyEdgeDeriver\.(derive|new)\b/
    allowed_callers = %w[manual_batch_ingestion_service.rb single_file_chunking_service.rb]

    callers = Dir.glob(Rails.root.join("app/**/*.rb").to_s).select do |path|
      next false if path.end_with?("topology_edge_deriver.rb")
      next false if allowed_callers.any? { |name| path.end_with?(name) }

      File.readlines(path).any? { |source_line| !source_line.match?(/\A\s*#/) && source_line.match?(invocation) }
    end

    assert_empty callers, "TopologyEdgeDeriver must not be called outside the Fase 4 ingestion callers: #{callers}"
  end

  private

  def page_layout(words:, lines:, rects: [], images: [])
    {
      page_number: 1, media_box: [ 0, 0, 960, 540 ],
      words: words, lines: lines, rects: rects,
      images: images, text_layer_chars: 0, image_area_ratio: 0.0
    }
  end

  def printed_word(text, x0, y0, x1, y1)
    { text: text, bbox: [ x0.to_f, y0.to_f, x1.to_f, y1.to_f ] }
  end

  # `rotated` is additive in Fase 2's contract (I-19): present and true on a
  # turned glyph, absent everywhere else.
  def rotated_word(text, x0, y0, x1, y1)
    printed_word(text, x0, y0, x1, y1).merge(rotated: true)
  end

  def image(x0, y0, x1, y1)
    { name: "Photo", width: 320, height: 240, size_class: :small,
      bbox: [ x0.to_f, y0.to_f, x1.to_f, y1.to_f ] }
  end

  # ------------------------------------- printed geometry, read from fixture --
  #
  # The next three read the page the same way the guard does but from the
  # fixture, so an assertion about a real page is a statement about the PDF and
  # not a restatement of the class under test.

  def bbox_gap(box_a, box_b)
    dx = [ box_b[0] - box_a[2], box_a[0] - box_b[2], 0.0 ].max
    dy = [ box_b[1] - box_a[3], box_a[1] - box_b[3], 0.0 ].max
    [ dx, dy ].max
  end

  def smallest_image_containing(layout, point)
    layout[:images].filter_map { |entry| entry[:bbox] if entry[:bbox]&.size == 4 }
                   .select { |bbox| point[0].between?(bbox[0], bbox[2]) && point[1].between?(bbox[1], bbox[3]) }
                   .min_by { |bbox| (bbox[2] - bbox[0]) * (bbox[3] - bbox[1]) }
  end

  def nearest_word_gap(layout, image_bbox, &selector)
    layout[:words].select(&selector).map { |word| bbox_gap(word[:bbox], image_bbox) }.min
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
  # chain running under the label it would claim, a terminal-number row, a wire
  # ending inside a photo another name is closer to, and one ending at a rotated
  # terminal marking.
  def known_bad_layout
    page_layout(
      words: [
        printed_word("LIMITADOR", 504, 154, 541, 161),
        printed_word("CONECTOR AI", 316, 231, 382, 240),
        printed_word("FOTOCELULA", 709, 106, 761, 114),
        printed_word("OBSTACULO", 862, 112, 909, 119),
        printed_word("1  2  3  4  5  6", 100, 300, 180, 310),
        printed_word("PISO SUPERIOR", 60, 380, 120, 390),
        printed_word("CC1", 60, 431, 80, 439),
        printed_word("CN9", 300, 460, 330, 470),
        rotated_word("B", 400, 470, 409, 487)
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
        segment(200, 290, 200, 340), segment(199, 341, 150, 341),
        # a wire into the strip photo CC1 names, with PISO SUPERIOR beside it
        segment(140, 405, 90, 405),
        # a wire to a rotated terminal marking
        segment(345, 465, 390, 470)
      ],
      images: [ image(50, 400, 130, 430) ]
    )
  end
end
