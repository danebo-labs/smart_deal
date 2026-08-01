# frozen_string_literal: true

# Per-page chain autopsy for Gate A manual review.
#   GATE_A_PAGES=3,17 bin/rails runner script/gate_a/page.rb

PDF_PATH = ENV.fetch(
  "GATE_A_PDF",
  "/Users/lahirisan/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf"
)
ONLY = ENV.fetch("GATE_A_PAGES").split(",").map(&:to_i)

binary = File.binread(PDF_PATH)

PdfPageSplitterService.new(binary).each_page do |page_number, page_binary|
  next unless ONLY.include?(page_number)

  layout  = PdfLayoutExtractor.extract(page_binary, page_number: page_number)
  d       = TopologyEdgeDeriver.new(layout)
  labels  = d.send(:labels)
  chains  = d.send(:chains)

  puts "=" * 78
  puts "PAGE #{page_number} — #{d.send(:segments).size} segs, #{labels.size} labels, #{chains.size} chains"
  puts "LABELS:"
  labels.sort_by { |l| [ -l.bbox[3], l.bbox[0] ] }.each do |l|
    puts "  %-42s x %6.1f-%-6.1f y %6.1f-%-6.1f" % [ l.text.inspect, *l.bbox.values_at(0, 2, 1, 3) ]
  end
  puts "CHAINS:"
  chains.each_with_index do |chain, i|
    head = d.send(:point_at, chain[:head])
    tail = d.send(:point_at, chain[:tail])
    poly = d.send(:polyline, chain)
    near = lambda do |pt|
      labels.map { |l| [ d.send(:chebyshev_gap, pt, l.bbox).round(1), l.text ] }
            .select { |gap, _| gap <= 40 }.sort.map { |gap, t| "#{t}@#{gap}" }.join(", ")
    end
    puts "  [#{i}] #{chain[:ids].size} seg  #{poly.inspect}"
    puts "      head (#{head[0].round(1)},#{head[1].round(1)}) dead_end=#{d.send(:dead_end?, head, chain[:ids])} near: #{near.call(head)}"
    puts "      tail (#{tail[0].round(1)},#{tail[1].round(1)}) dead_end=#{d.send(:dead_end?, tail, chain[:ids])} near: #{near.call(tail)}"
  end
  puts "EDGES: #{d.derive.map { |e| "#{e[:from]} <-> #{e[:to]}" }.inspect}"
end
