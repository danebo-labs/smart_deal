# frozen_string_literal: true

# Gate A sensitivity probe: how much of T1's silence is the 4-segment chain cap
# (and the Fase 2 noise cut of I-10), and not missing evidence?
#
# Nothing here is a proposed change — it measures the cost of two constants so
# Fase 5 can be sized against evidence instead of a guess.
#
#   bin/rails runner script/gate_a/sensitivity.rb

PDF_PATH = ENV.fetch(
  "GATE_A_PDF",
  "/Users/lahirisan/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf"
)

def with_constant(mod, name, value)
  old = mod.const_get(name)
  mod.send(:remove_const, name)
  mod.const_set(name, value)
  yield
ensure
  mod.send(:remove_const, name)
  mod.const_set(name, old)
end

binary  = File.binread(PDF_PATH)
layouts = {}
noisy   = {}

PdfPageSplitterService.new(binary).each_page do |n, page_binary|
  layouts[n] = PdfLayoutExtractor.extract(page_binary, page_number: n)
  with_constant(PdfLayoutExtractor, :LINE_NOISE_MAX_MANHATTAN_PT, 2) do
    noisy[n] = PdfLayoutExtractor.extract(page_binary, page_number: n)
  end
end

def tally(layouts, label)
  edges = layouts.transform_values { |l| TopologyEdgeDeriver.derive(l) }
  total = edges.values.sum(&:size)
  pages = edges.count { |_, e| e.any? }
  puts "#{label}: #{total} aristas en #{pages} páginas"
  edges
end

base = nil
[ 4, 6, 8, 12 ].each do |cap|
  with_constant(TopologyEdgeDeriver, :MAX_CHAIN_SEGMENTS, cap) do
    e = tally(layouts, "corte de ruido 20pt (actual) · cadena <=#{cap} seg")
    base = e if cap == 4
  end
end

puts
[ 4, 6, 8, 12 ].each do |cap|
  with_constant(TopologyEdgeDeriver, :MAX_CHAIN_SEGMENTS, cap) do
    tally(noisy, "corte de ruido 2pt · cadena <=#{cap} seg")
  end
end

puts
puts "--- página 3, corte 2pt, cadena <=12 ---"
with_constant(TopologyEdgeDeriver, :MAX_CHAIN_SEGMENTS, 12) do
  TopologyEdgeDeriver.derive(noisy[3]).each { |e| puts "  #{e[:from]} <-> #{e[:to]}" }
end
