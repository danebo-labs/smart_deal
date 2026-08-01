# frozen_string_literal: true

# Second Gate A pass: why chains never form. TopologyEdgeDeriver#chains silently
# drops a walk that hits a branch, revisits a segment or exceeds 4 segments, so
# those losses are invisible in the per-chain rejection tally.
#
#   bin/rails runner script/gate_a/walk.rb

PDF_PATH = ENV.fetch(
  "GATE_A_PDF",
  "/Users/lahirisan/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf"
)
OUT_PATH = ENV.fetch("GATE_A_WALK_OUT", "tmp/gate_a_walk.json")
ONLY = ENV["GATE_A_PAGES"]&.split(",")&.map(&:to_i)

def walk_reason(deriver, head)
  ids = []
  current = head
  loop do
    return :too_long if ids.size >= TopologyEdgeDeriver::MAX_CHAIN_SEGMENTS
    return :revisit  if ids.include?(current[0])

    ids << current[0]
    exit_key = [ current[0], 1 - current[1] ]
    peers = deriver.send(:joint_clusters)[exit_key] - [ exit_key ]
    return :ok if peers.empty?
    return :branch unless peers.size == 1

    current = peers.first
  end
end

binary = File.binread(PDF_PATH)
rows = []

PdfPageSplitterService.new(binary).each_page do |page_number, page_binary|
  next if ONLY && ONLY.exclude?(page_number)

  layout  = PdfLayoutExtractor.extract(page_binary, page_number: page_number)
  deriver = TopologyEdgeDeriver.new(layout)
  segments = deriver.send(:segments)
  clusters = deriver.send(:joint_clusters)
  keys = deriver.send(:endpoint_keys)

  dead_ends = keys.select { |k| clusters[k].size == 1 }
  joints    = keys.count { |k| clusters[k].size == 2 }
  branches  = keys.count { |k| clusters[k].size >= 3 }

  tally = Hash.new(0)
  dead_ends.each { |k| tally[walk_reason(deriver, k)] += 1 }

  rows << {
    page: page_number, segments: segments.size,
    dead_end_endpoints: dead_ends.size, joint_endpoints: joints, branch_endpoints: branches,
    walk: tally
  }
  warn("p#{page_number} segs=#{segments.size} dead_ends=#{dead_ends.size} branch_eps=#{branches} walk=#{tally.to_a.inspect}")
end

File.write(OUT_PATH, JSON.pretty_generate(rows))
agg = Hash.new(0)
rows.each { |r| r[:walk].each { |k, v| agg[k] += v } }
warn("TOTAL walk outcomes: #{agg.sort_by { |_, v| -v }.to_h}")
warn("TOTAL endpoints: dead=#{rows.sum { |r| r[:dead_end_endpoints] }} joint=#{rows.sum { |r| r[:joint_endpoints] }} branch=#{rows.sum { |r| r[:branch_endpoints] }}")
