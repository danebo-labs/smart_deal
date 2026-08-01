# frozen_string_literal: true

# Gate A: LED-table rows and their grouping, bounded by the table's own drawn
# rules instead of a guessed window.
#
#   bin/rails runner script/gate_a/led.rb

PDF_PATH = ENV.fetch(
  "GATE_A_PDF",
  "/Users/lahirisan/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf"
)

ROW_Y_TOLERANCE = 4.0
MAX_RULE_GAP_PT = 32.0

def horizontal_rules(layout)
  rules = Array(layout[:lines]).filter_map do |line|
    from = line[:from]
    to   = line[:to]
    next unless (from[1] - to[1]).abs <= 1.0

    { y: (from[1] + to[1]) / 2.0, x0: [ from[0], to[0] ].min, x1: [ from[0], to[0] ].max }
  end
  Array(layout[:rects]).each do |rect|
    x0, y0, x1, y1 = rect[:bbox]
    rules << { y: y0, x0: x0, x1: x1 } << { y: y1, x0: x0, x1: x1 }
  end
  rules
end

report = []
binary = File.binread(PDF_PATH)

PdfPageSplitterService.new(binary).each_page do |page_number, page_binary|
  layout = PdfLayoutExtractor.extract(page_binary, page_number: page_number)
  words  = Array(layout[:words])
  header = words.find { |w| w[:text].to_s.strip == "LED" }
  next unless header

  hx0, hy0, = header[:bbox]

  # The rule stack of the table: rules under the header that span its column and
  # sit no more than one row apart. The lowest one is the table's bottom edge.
  stack = horizontal_rules(layout)
          .select { |r| r[:y] < hy0 && r[:x0] <= hx0 + 5 && r[:x1] >= hx0 + 40 }
          .map { |r| r[:y] }.uniq.sort.reverse
  bottom = hy0
  stack.each do |y|
    break if (bottom - y) > MAX_RULE_GAP_PT

    bottom = y
  end

  body = words.select { |w| w[:bbox][3] < hy0 && w[:bbox][1] > bottom - 2 }
  rows = body.group_by { |w| (w[:bbox][1] / ROW_Y_TOLERANCE).round }
             .values.map { |ws| ws.sort_by { |w| w[:bbox][0] } }
             .sort_by { |ws| -ws.first[:bbox][1] }

  columns = words.select { |w| (w[:bbox][1] - hy0).abs <= ROW_Y_TOLERANCE }
                 .sort_by { |w| w[:bbox][0] }.map { |w| w[:text].to_s.strip }

  report << {
    page: page_number, columns: columns, bottom: bottom.round(1),
    rows: rows.map { |row| row.map { |w| w[:text].to_s.strip } }
  }
end

report.each do |r|
  puts "p#{r[:page]}  columnas=#{r[:columns].inspect}  filas=#{r[:rows].size}"
  r[:rows].each { |row| puts "     #{row.inspect}" }
end
puts
puts "TOTAL: #{report.size} páginas con tabla LED, #{report.sum { |r| r[:rows].size }} filas"
File.write("tmp/gate_a_led.json", JSON.pretty_generate(report))
