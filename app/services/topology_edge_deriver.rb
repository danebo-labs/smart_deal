# frozen_string_literal: true

# Derives T1 topology edges (label ↔ label, joined by a drawn leader line) from
# the page geometry `PdfLayoutExtractor` produces. Offline groundwork for
# docs/rag/plan_conocimiento_visual.md (Fase 3); Fase 4 consumes the output.
# Nothing in production calls this yet.
#
# Coordinate convention is HexaPDF's, inherited unchanged from Fase 2: y grows
# UPWARD from the bottom of the page.
#
# Result (docs/rag/plan_conocimiento_visual.md, "Contratos de datos"):
#   [ { from: "LIMITADOR", to: "CONECTOR AI", method: :leader_line,
#       evidence: "polilínea (…) une LIMITADOR (…) con CONECTOR AI (…)",
#       chain: [[485.6, 154.9], [405.2, 154.0], [405.8, 248.1]] } ]
#
# A label that does not resolve simply does not appear. There are no partial
# entries, no nils and no numeric confidence. `[]` is a valid and frequent
# answer — every divider page returns it, and so does every page whose leader
# lines end on a photo or on an unlabelled terminal strip.
#
# WHY THE GUARDS ARE THE WHOLE JOB
#
# A cited edge that is not drawn on the page is the worst failure this system
# can produce, so every rule below is a rejection rule and every one of them was
# fixed against measured geometry from `SEGURIDADES 1.1-1.pdf` (pages 3, 17, 32,
# 63 and the divider page 2), not chosen by feel:
#
#   * a chain is a run of segments joined END TO END. A junction where three or
#     more endpoints meet is a branch: the chain through it is dropped, not
#     guessed. This is what removes the page frame (four coincident borders) and
#     drawn boxes;
#   * a terminal that lands on another segment's INTERIOR is a T-junction, not a
#     dead end — it is dropped. This is what removes table rules, whose ends
#     touch the table's outer box (measured on page 3: the LED table's three row
#     separators end 0.75 pt from the box verticals);
#   * ≤4 segments per chain;
#   * a terminal must sit inside exactly ONE printed label's bbox grown by
#     TERMINAL_TOLERANCE_PT. Zero labels, or two, and nothing is emitted;
#   * a chain may not claim a label it RUNS PAST. Measured counter-example,
#     page 32: a wire from connector CN7 to the OBSTACULO device passes 5.2 pt
#     under the printed `FOTOCELULA`, whose left edge is 14 pt from the wire's
#     end — near enough to resolve, and wrong. A label the chain skims within
#     one text line height is captioning the route, not naming the end;
#   * both ends must resolve to DIFFERENT labels. On page 3 the leader lines are
#     drawn as loops that leave one terminal of a connector, pass through a
#     component photo and return to another terminal of the SAME connector; both
#     ends resolve to `CONECTOR AI` and nothing is emitted, which is correct —
#     the component in the middle of the loop is not named by any endpoint;
#   * a terminal that lands inside an image may only be named by a label no
#     other printed label sits closer to (Fase 3b/I-14) — see RASTER RIVALS;
#   * a rotated label never names a terminal (Fase 3b, on Fase 2b/I-13).
#
# RASTER RIVALS
#
# The uniqueness rule above is only as good as the text layer: it can only see
# rivals that are PRINTED. Measured over the whole of `SEGURIDADES 1.1-1.pdf`
# (Gate A §4.3), the terminal numbering of a connector strip is usually drawn
# INSIDE the photo of the strip, so the rival that should have made the terminal
# ambiguous is pixels and the guard passes a label that names something else.
# Page 56 emitted `PISO SUPERIOR -> CC2` for a wire between two connectors, and
# page 97 emitted `PUERTAS FRONTALES -> PESTLLOS TECHO CABINA` for two devices
# no wire joins.
#
# So a terminal inside an image is only allowed to be named by the label that
# names THAT image: no other printed label may sit closer to it. `images[].bbox`
# comes from Fase 2 (I-07) and this is its first consumer. Measured gaps from
# each terminal's image to the labels around it:
#
#   page 3   `LIMITADOR`               0.00  nearest — the text overlaps the
#                                            limiter photo the wire ends on ✓
#   page 63  `J12`                    16.03  nearest — the connector's own name,
#                                            printed to the left of its strip ✓
#   page 56  `PISO SUPERIOR`          19.12  third: `CC1` at 13.18 (the strip's
#                                            own name) and `PISO INFERIOR` at
#                                            18.23 are closer ✗
#   page 97  `PESTLLOS TECHO CABINA`   6.56  third, behind two connector-name
#                                            rows overlapping the strip ✗
#
# The two full-page background images every page in this document carries are
# inert under this rule: every label is inside them, so no label is closer than
# any other and they raise no objection.
#
# ROTATED LABELS
#
# Fase 2 marks a word `rotated: true` when its glyphs are turned 90° (I-13,
# I-19). Its `text` is not in reading order and must never be quoted: page 67's
# printed `ES` reached Fase 3 as `SE`, and page 61's `P35B` as `B` — both were
# emitted as edge endpoints. Fase 2b's corrected boxes did not end that: page 61
# then emitted `A 8 2 P` for the printed terminal `P28A` (I-21). Correcting the
# geometry only changes which garbage gets quoted; refusing to quote it is this
# guard. A rotated label is dropped as a terminal name but stays in the label
# set — it is still a rival for the uniqueness rule, and still a label a chain
# can run past.
#
# The `ACUÑAMIENTO` case of the plan's Apéndice D resolves to (c) "no edge" by
# these rules: no chain terminal lands within tolerance of that label. The green
# leader line only PASSES it (6.4 pt to the right of the label, running from
# y=21 to y=154), so there is no evidence of a terminus, and proximity in x —
# which is what would have put it on CONECTOR AG — is never consulted.
#
# `method: :column_proximity` is deliberately not implemented. The enum stays
# open to `:vision` for Fase 5.
class TopologyEdgeDeriver
  # Two segment endpoints belong to the same joint when they are this close.
  # PowerPoint elbow connectors are stroked, and each straight run is emitted to
  # its own edge of the stroke, so a corner leaves a small gap; the rounded part
  # of the corner is a Bézier, which Fase 2 does not emit at all. Measured on
  # page 3: real joints are 1.30–1.92 pt apart, and the nearest pair of
  # endpoints that must NOT be joined is 10.9 pt apart. 2.5 pt sits in that
  # valley with >4x margin either way.
  JOINT_TOLERANCE_PT = 2.5

  # Same magnitude, different question: how close a terminal may be to another
  # segment's interior before it counts as a T-junction instead of a dead end.
  T_JUNCTION_TOLERANCE_PT = 2.5

  # Fixed by the plan. Long chains are where mis-joins compound.
  MAX_CHAIN_SEGMENTS = 4

  # How far outside a printed label's bbox a terminal may land and still be read
  # as terminating at it. This is the one genuinely loose number, so it is
  # measured rather than assumed: the leader lines in this document class end on
  # a component PHOTO or on a terminal of a connector STRIP, and the printed
  # label sits beside that graphic. Largest true gap measured:
  #
  #   23.7 pt  page 3, brown cable → `CONECTOR AI` (it enters terminal 1, which
  #            is outside the red pill that carries the printed name)
  #   22.8 pt  page 63, blue cable → `ALUMBRADO CABINA` (ends at the lamp; the
  #            text is to the right of the lamp)
  #   18.8 pt  page 3, brown cable → `LIMITADOR` (ends on the limiter photo)
  #
  # 25 pt covers all three with margin. Distance is NOT what makes this safe:
  # the uniqueness rule is. A terminal within 25 pt of two labels is ambiguous
  # and is dropped, and on page 3 that is what rejects the table (three of its
  # row separators sit within 25 pt of two or three of `DL2`/`DL3`/`DL4`).
  # Compared per axis (Chebyshev), i.e. literally "inside the bbox grown by 25".
  TERMINAL_TOLERANCE_PT = 25.0

  # Two printed words belong to the same label when one sits directly under the
  # other. `words` groups glyphs by visual adjacency within a text line (I-08),
  # so a stacked label such as `STOP` / `FOSO` arrives as two entries and the
  # verbatim the plan's Apéndice D requires (`STOP FOSO`, `BOTO. REVISION`,
  # `CERROJOS EMBARQUE 1`) only exists after this merge. Measured on page 3:
  # lines of one label are 2.3 pt apart with a 7.3 pt glyph height (0.32), while
  # the rows of the LED table are 10.5 pt apart at 8.8 pt (1.19).
  LABEL_STACK_GAP_RATIO     = 0.6
  LABEL_STACK_MIN_OVERLAP   = 0.5

  # Not every entry in `words` names a component or a connector, and a terminal
  # that resolves to something that is not a name produces a citation nobody can
  # act on. Each of these four rejections comes from a measured page:
  #
  #   too long / spaced   `CN37   C   N   2   5   C   N   3   3…` (page 97) and
  #                       `C1 C 2  C3  C4  C5  C6` (page 95) are whole rows of
  #                       connector names that Fase 2's glyph grouping merged
  #                       into one box. Stacked labels this class builds are
  #                       joined with a single space, so a run of two is the
  #                       tell; and a real label here is far under 60 characters
  #                       (the longest in the plan's Apéndice D is 22)
  #   no letter           `4  5  6  7  8  9  10 11 1 2` (page 93) is the printed
  #                       terminal numbering of a block, not its name
  #   annotation          `(NO)` / `(NC)` (page 14) mark contact state. Page 14
  #                       prints `(NO)` three times, each beside a different
  #                       device; the nearest one to a wire end is not that
  #                       device's name
  MAX_LABEL_CHARACTERS = 60
  MERGED_ROW_MARKER    = /\s{2,}/
  ANNOTATION_ONLY      = /\A\(.*\)\z/

  Label = Struct.new(:text, :bbox, :line_height, :rotated, keyword_init: true)
  private_constant :Label

  # @param layout [Hash] one page's `PdfLayoutExtractor` result
  # @return [Array<Hash>]
  def self.derive(layout)
    new(layout).derive
  end

  def initialize(layout)
    @layout = layout || {}
  end

  def derive
    return [] if segments.empty? || labels.empty?

    # One pair, one edge: a device wired in and out of the same connector draws
    # two chains between the same two labels (page 12), and the second states
    # nothing the first did not. Sorted before de-duplicating so which chain
    # survives is stable across runs, and so is Fase 4's RECORD_ID.
    chains.filter_map { |chain| edge_for(chain) }
          .sort_by { |edge| [ edge[:from], edge[:to], edge[:chain].flatten ] }
          .uniq { |edge| [ edge[:from], edge[:to] ].sort }
  end

  private

  def segments
    @segments ||= Array(@layout[:lines]).filter_map do |line|
      from = Array(line[:from]).map(&:to_f)
      to   = Array(line[:to]).map(&:to_f)
      next unless from.size == 2 && to.size == 2
      next if from == to

      [ from, to ]
    end
  end

  # ---------------------------------------------------------------- labels ---

  def labels
    @labels ||= build_labels
  end

  def build_labels
    words = Array(@layout[:words]).filter_map do |word|
      text = word[:text].to_s.strip
      bbox = Array(word[:bbox]).map(&:to_f)
      next if text.empty? || bbox.size != 4

      # `rotated` is additive in Fase 2's contract: present and true, or absent.
      # Never compare it to false (I-19).
      { text: text, bbox: bbox, rotated: word[:rotated] == true }
    end

    group_stacked(words).map do |group|
      ordered = group.sort_by { |word| -word[:bbox][3] }
      Label.new(
        text: ordered.map { |word| word[:text] }.join(" "),
        bbox: [
          ordered.map { |w| w[:bbox][0] }.min, ordered.map { |w| w[:bbox][1] }.min,
          ordered.map { |w| w[:bbox][2] }.max, ordered.map { |w| w[:bbox][3] }.max
        ],
        line_height: ordered.map { |w| w[:bbox][3] - w[:bbox][1] }.max,
        rotated: ordered.any? { |word| word[:rotated] }
      )
    end
  end

  # Union-find over the ORIGINAL word boxes: the pairwise test never sees a
  # merged box, so a growing block cannot keep swallowing its neighbours.
  def group_stacked(words)
    parent = (0...words.size).to_a
    words.each_index do |i|
      ((i + 1)...words.size).each do |j|
        next unless stacked?(words[i], words[j])

        root_i, root_j = find_root(parent, i), find_root(parent, j)
        parent[root_i] = root_j unless root_i == root_j
      end
    end

    words.each_index.group_by { |i| find_root(parent, i) }
         .values.map { |indexes| indexes.map { |i| words[i] } }
  end

  # A turned glyph and an upright one are never two lines of one printed label,
  # so they do not stack. Without this, page 61's vertical terminal markings
  # merge into the labels beside them and carry `rotated` — and the guard
  # below — into a name that was printed perfectly straight.
  def stacked?(word_a, word_b)
    return false unless word_a[:rotated] == word_b[:rotated]

    ax0, ay0, ax1, ay1 = word_a[:bbox]
    bx0, by0, bx1, by1 = word_b[:bbox]

    overlap = [ ax1, bx1 ].min - [ ax0, bx0 ].max
    return false if overlap < LABEL_STACK_MIN_OVERLAP * [ ax1 - ax0, bx1 - bx0 ].min

    gap = by0 > ay1 ? by0 - ay1 : ay0 - by1
    return false if gap.negative?
    return false if gap > LABEL_STACK_GAP_RATIO * [ ay1 - ay0, by1 - by0 ].max

    !ruled_apart?(word_a, word_b)
  end

  # A printed multi-line label is not interrupted by a drawn rule. Two words
  # separated by one are table rows, not one label — measured on page 17, whose
  # table rows sit 3.2 pt apart (0.36 of glyph height) and would otherwise merge
  # into `PS2V… PS2VH ….`.
  def ruled_apart?(word_a, word_b)
    low  = [ word_a[:bbox][3], word_b[:bbox][3] ].min
    high = [ word_a[:bbox][1], word_b[:bbox][1] ].max
    x0   = [ word_a[:bbox][0], word_b[:bbox][0] ].max
    x1   = [ word_a[:bbox][2], word_b[:bbox][2] ].min

    horizontal_rules.any? do |rule|
      rule[:y] > low && rule[:y] < high && rule[:x0] <= x1 && rule[:x1] >= x0
    end
  end

  def horizontal_rules
    @horizontal_rules ||= begin
      rules = segments.filter_map do |from, to|
        next unless (from[1] - to[1]).abs <= 1.0

        { y: (from[1] + to[1]) / 2.0, x0: [ from[0], to[0] ].min, x1: [ from[0], to[0] ].max }
      end

      Array(@layout[:rects]).each do |rect|
        bbox = Array(rect[:bbox]).map(&:to_f)
        next unless bbox.size == 4

        rules << { y: bbox[1], x0: bbox[0], x1: bbox[2] }
        rules << { y: bbox[3], x0: bbox[0], x1: bbox[2] }
      end

      rules
    end
  end

  # ---------------------------------------------------------------- chains ---

  # Endpoint keys are [segment_index, 0|1]; joints are the union-find clusters
  # of those keys. Cluster of 1 = a dead end. Cluster of 2 = a joint. Cluster of
  # 3+ = a branch, and a chain that reaches one is abandoned.
  def endpoint_keys
    @endpoint_keys ||= segments.each_index.flat_map { |i| [ [ i, 0 ], [ i, 1 ] ] }
  end

  def joint_clusters
    @joint_clusters ||= begin
      keys   = endpoint_keys
      parent = (0...keys.size).to_a

      keys.each_with_index do |key_a, a|
        ((a + 1)...keys.size).each do |b|
          next if key_a[0] == keys[b][0]
          next if distance(point_at(key_a), point_at(keys[b])) > JOINT_TOLERANCE_PT

          root_a, root_b = find_root(parent, a), find_root(parent, b)
          parent[root_a] = root_b unless root_a == root_b
        end
      end

      members = Hash.new { |hash, root| hash[root] = [] }
      keys.each_with_index { |key, i| members[find_root(parent, i)] << key }
      keys.each_with_index.to_h { |key, i| [ key, members[find_root(parent, i)] ] }
    end
  end

  def chains
    seen = {}

    endpoint_keys.filter_map do |key|
      next unless joint_clusters[key].size == 1
      next if seen[key]

      chain = walk_from(key)
      next unless chain

      seen[chain[:tail]] = true
      chain
    end
  end

  # Walks segment to segment out of a dead end. Returns nil the moment the walk
  # hits a branch, revisits a segment, or grows past MAX_CHAIN_SEGMENTS.
  def walk_from(head)
    ids     = []
    entries = []
    current = head

    loop do
      return nil if ids.size >= MAX_CHAIN_SEGMENTS
      return nil if ids.include?(current[0])

      ids << current[0]
      entries << current
      exit_key = [ current[0], 1 - current[1] ]
      peers    = joint_clusters[exit_key] - [ exit_key ]

      return { ids: ids, entries: entries, head: head, tail: exit_key } if peers.empty?
      return nil unless peers.size == 1

      current = peers.first
    end
  end

  # ----------------------------------------------------------------- edges ---

  def edge_for(chain)
    head_point = point_at(chain[:head])
    tail_point = point_at(chain[:tail])
    return nil unless dead_end?(head_point, chain[:ids])
    return nil unless dead_end?(tail_point, chain[:ids])

    head_label = sole_label_at(head_point, chain)
    tail_label = sole_label_at(tail_point, chain)
    return nil if head_label.nil? || tail_label.nil?
    return nil if head_label.text == tail_label.text

    build_edge(chain, [ head_point, head_label ], [ tail_point, tail_label ])
  end

  # A terminal that touches another segment's interior is a T-junction: the two
  # lines meet, so this is not the end of anything.
  def dead_end?(point, own_ids)
    segments.each_with_index.none? do |(from, to), index|
      next false if own_ids.include?(index)

      point_on_segment_interior?(point, from, to)
    end
  end

  # Ambiguity is judged over ALL labels, including the unusable, the rotated and
  # the ones an image outranks: dropping any of them from the candidate set
  # early would turn "two labels in range" — which must be rejected — into a
  # clean single hit. Every rejection below therefore runs on the sole
  # survivor, never on the set.
  def sole_label_at(point, chain)
    found = labels.select { |label| terminates_at?(point, chain, label) }
    return nil unless found.size == 1

    label = found.first
    return nil if label.rotated
    return nil unless nameable?(label)
    return nil if outranked_on_an_image?(point, label)

    label
  end

  # True when the terminal lands inside an image and a DIFFERENTLY named printed
  # label sits strictly closer to that image than the candidate does — that
  # image carries a name of its own, in pixels this class cannot read, and the
  # label beside it is not it.
  #
  # Two exclusions from the comparison, both measured:
  #
  #   * a label printed with the same text is not a rival — it cannot make the
  #     citation wrong. Page 39 prints `CERROJOS EXTERIORES` twice, above and
  #     below the same photo, 1.14 pt and 4.22 pt from it; without this the
  #     correct edge dies to its own name;
  #   * rotated labels are the strip's own terminal markings, they can never
  #     name an endpoint themselves, and on page 63 four of them sit 1.2–4.0 pt
  #     from the connector image that `J12` — the correct answer, 16.0 pt away —
  #     legitimately names.
  def outranked_on_an_image?(point, label)
    image_boxes.any? do |image|
      next false unless point_inside?(point, image)

      nearest_rival_gap(image, label.text) < bbox_gap(label.bbox, image)
    end
  end

  # Fase 2 reports `bbox: nil` for an XObject declared but never painted (I-07):
  # no known position, so no opinion.
  def image_boxes
    @image_boxes ||= Array(@layout[:images]).filter_map do |image|
      bbox = Array(image[:bbox]).map(&:to_f)
      bbox if bbox.size == 4
    end
  end

  def nearest_rival_gap(image, text)
    @nearest_rival_gap ||= {}
    @nearest_rival_gap[[ image, text ]] ||=
      labels.reject { |label| label.rotated || label.text == text }
            .map { |label| bbox_gap(label.bbox, image) }.min || Float::INFINITY
  end

  def nameable?(label)
    text = label.text
    return false if text.length > MAX_LABEL_CHARACTERS
    return false if text.match?(MERGED_ROW_MARKER)
    return false if text.match?(ANNOTATION_ONLY)

    text.match?(/[[:alpha:]]/)
  end

  def terminates_at?(point, chain, label)
    return false if chebyshev_gap(point, label.bbox) > TERMINAL_TOLERANCE_PT

    !passes_by?(chain, label)
  end

  # True when any segment of the chain runs through the label's bbox grown by
  # one text line height — the chain skims the label instead of ending clear of
  # it, so the label describes the route rather than the terminus.
  def passes_by?(chain, label)
    clearance = label.line_height
    box = [
      label.bbox[0] - clearance, label.bbox[1] - clearance,
      label.bbox[2] + clearance, label.bbox[3] + clearance
    ]

    chain[:ids].any? { |id| segment_intersects_box?(segments[id][0], segments[id][1], box) }
  end

  def build_edge(chain, head, tail)
    head_first = (comparable(head.first) <=> comparable(tail.first)) <= 0
    first, second = head_first ? [ head, tail ] : [ tail, head ]
    vertices = polyline(chain)
    vertices = vertices.reverse unless head_first

    {
      from:     first.last.text,
      to:       second.last.text,
      method:   :leader_line,
      evidence: evidence_for(vertices, first.last, second.last),
      chain:    vertices
    }
  end

  # Reading order of the two terminals, bottom of the page first. This orders
  # the pair so the output (and Fase 4's RECORD_ID) is stable; it is NOT a claim
  # about which end is the component and which is the connector. Nothing in the
  # geometry says that, so nothing here pretends to know it.
  def comparable(point)
    [ point[1], point[0] ]
  end

  # One vertex per corner: the two endpoints that form a joint are ~1.4 pt
  # apart, so the corner is reported as their midpoint.
  def polyline(chain)
    points = [ point_at(chain[:head]) ]
    chain[:entries].each_with_index do |entry, position|
      exit_key = [ entry[0], 1 - entry[1] ]
      next_entry = chain[:entries][position + 1]
      points << if next_entry
                  midpoint(point_at(exit_key), point_at(next_entry))
      else
                  point_at(exit_key)
      end
    end
    points.map { |point| point.map { |value| value.round(1) } }
  end

  def evidence_for(vertices, first, second)
    drawn = vertices.map { |x, y| "(#{x},#{y})" }.join("->")
    "polilínea #{drawn} une #{describe(first)} con #{describe(second)}"
  end

  def describe(label)
    x0, y0, x1, y1 = label.bbox.map(&:round)
    "#{label.text} (x #{x0}-#{x1}, y #{y0}-#{y1})"
  end

  # -------------------------------------------------------------- geometry ---

  def point_at(key)
    segments[key[0]][key[1]]
  end

  def midpoint(point_a, point_b)
    [ (point_a[0] + point_b[0]) / 2.0, (point_a[1] + point_b[1]) / 2.0 ]
  end

  def distance(point_a, point_b)
    Math.hypot(point_a[0] - point_b[0], point_a[1] - point_b[1])
  end

  def point_inside?(point, bbox)
    point[0] >= bbox[0] && point[0] <= bbox[2] && point[1] >= bbox[1] && point[1] <= bbox[3]
  end

  # Chebyshev gap between two boxes: 0 when they touch or overlap.
  def bbox_gap(box_a, box_b)
    dx = [ box_b[0] - box_a[2], box_a[0] - box_b[2], 0.0 ].max
    dy = [ box_b[1] - box_a[3], box_a[1] - box_b[3], 0.0 ].max
    [ dx, dy ].max
  end

  def chebyshev_gap(point, bbox)
    dx = [ bbox[0] - point[0], 0.0, point[0] - bbox[2] ].max
    dy = [ bbox[1] - point[1], 0.0, point[1] - bbox[3] ].max
    [ dx, dy ].max
  end

  def point_on_segment_interior?(point, from, to)
    vx = to[0] - from[0]
    vy = to[1] - from[1]
    length_squared = (vx * vx) + (vy * vy)
    return false if length_squared.zero?

    t = (((point[0] - from[0]) * vx) + ((point[1] - from[1]) * vy)) / length_squared
    return false if t <= 0.0 || t >= 1.0

    projection = [ from[0] + (t * vx), from[1] + (t * vy) ]
    distance(point, projection) <= T_JUNCTION_TOLERANCE_PT
  end

  # Liang-Barsky clip of the segment against the axis-aligned box.
  def segment_intersects_box?(from, to, box)
    t0 = 0.0
    t1 = 1.0
    dx = to[0] - from[0]
    dy = to[1] - from[1]

    [ [ -dx, from[0] - box[0] ], [ dx, box[2] - from[0] ],
      [ -dy, from[1] - box[1] ], [ dy, box[3] - from[1] ] ].each do |p, q|
      if p.zero?
        return false if q.negative?

        next
      end

      r = q / p
      if p.negative?
        return false if r > t1

        t0 = r if r > t0
      else
        return false if r < t0

        t1 = r if r < t1
      end
    end

    true
  end

  def find_root(parent, index)
    index = parent[index] while parent[index] != index
    index
  end
end
