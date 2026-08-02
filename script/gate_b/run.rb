# frozen_string_literal: true

# Gate B driver (docs/rag/plan_conocimiento_visual.md): runs T2
# (VisionTopologyExtractor) over a chosen set of pages of SEGURIDADES 1.1-1.pdf
# and dumps, per page, T1's deterministic edges, T2's kept edges, T2's
# components, tokens and measured cost.
#
#   GATE_B_PAGES=3,17,63 GATE_B_OUT=tmp/gate_b_run1.json \
#     bin/rails runner script/gate_b/run.rb
#
# Set GATE_B_ZOOM_TILES=true to add the Fase 5b tiles (informe §10). Everything
# else is identical, so the two runs are comparable page by page.
#
# `traced_edges:` is deliberately EMPTY: the conflict policy (T1 wins) is
# applied here, in the report, so the same run can measure T2 against T1 (which
# needs T2's raw reading of a pair T1 already proved) and show what production
# would keep (which drops it).

require "json"

PDF_PATH = ENV.fetch(
  "GATE_B_PDF",
  "/Users/lahirisan/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf"
)
PAGES    = ENV.fetch("GATE_B_PAGES").split(",").map(&:to_i)
OUT_PATH = ENV.fetch("GATE_B_OUT", "tmp/gate_b_run.json")
LABEL    = ENV.fetch("GATE_B_LABEL", "run")
THREADS  = ENV.fetch("GATE_B_THREADS", "4").to_i
FILENAME = "SEGURIDADES 1.1-1.pdf"

# claude-opus-4-8 direct Messages API, USD per token.
IN_RATE  = 5.0 / 1_000_000
OUT_RATE = 25.0 / 1_000_000

ENV["INGESTION_VISION_TIER_ENABLED"] = "true"
# Relations are OFF in production since the Gate B verdict; the measurement has
# to see them or there is nothing to score.
ENV["INGESTION_VISION_TIER_RELATIONS_ENABLED"] = "true"
ENV["INGESTION_VISION_TIER_ZOOM_TILES"] = "true" if ENV["GATE_B_ZOOM_TILES"] == "true"

Rails.logger = ActiveSupport::Logger.new($stdout)
Rails.logger.level = Logger::INFO

binary = File.binread(PDF_PATH)

pages = {}
PdfPageSplitterService.new(binary).each_page do |page_number, page_binary|
  pages[page_number] = page_binary.dup if PAGES.include?(page_number)
end
total_pages = 98

warn "GATE B #{LABEL}: #{pages.size} pages, prompt=#{VisionTopologyPrompt::CONTRACT_VERSION} " \
     "fp=#{VisionTopologyPrompt.prompt_fingerprint_sha256[0, 12]} " \
     "zoom_tiles=#{IngestionVisionFlag.zoom_tiles_enabled?}"

results = {}
mutex   = Mutex.new
queue   = pages.keys.sort.dup

workers = Array.new([ THREADS, queue.size ].min) do
  Thread.new do
    loop do
      page_number = mutex.synchronize { queue.shift }
      break unless page_number

      page_binary = pages[page_number]
      started     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      layout      = PdfLayoutExtractor.extract(page_binary, page_number: page_number)
      t1          = TopologyEdgeDeriver.new(layout).derive
      eligible    = VisionTopologyExtractor.eligible?(layout: layout)

      result =
        if eligible
          VisionTopologyExtractor.derive(
            page_binary,
            layout:        layout,
            page_number:   page_number,
            total_pages:   total_pages,
            filename:      FILENAME,
            traced_edges:  [],
            locale:        "es",
            correlation_id: "gateb:#{LABEL}:p#{page_number}"
          )
        else
          VisionTopologyExtractor::Result.empty
        end

      record = {
        page:        page_number,
        eligible:    eligible,
        t1_edges:    t1.map { |e| { from: e[:from], to: e[:to], evidence: e[:evidence] } },
        t2_edges:    result.edges.map { |e| { from: e[:from], to: e[:to], evidence: e[:evidence] } },
        components:  result.components,
        crops:       result.crop_count,
        input_tokens:  result.input_tokens,
        output_tokens: result.output_tokens,
        cost_usd:    (result.input_tokens * IN_RATE + result.output_tokens * OUT_RATE).round(5),
        duration_s:  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
      }

      mutex.synchronize do
        results[page_number] = record
        warn "  p#{page_number}: T1=#{record[:t1_edges].size} T2=#{record[:t2_edges].size} " \
             "comp=#{record[:components].size} crops=#{record[:crops]} " \
             "$#{record[:cost_usd]} #{record[:duration_s]}s"
      end
    end
  end
end
workers.each(&:join)

ordered = results.keys.sort.map { |k| results[k] }
payload = {
  label:              LABEL,
  prompt_contract:    VisionTopologyPrompt::CONTRACT_VERSION,
  prompt_fingerprint: VisionTopologyPrompt.prompt_fingerprint_sha256,
  zoom_tiles:         IngestionVisionFlag.zoom_tiles_enabled?,
  model:              BatchChunkingPrompt::MODEL_MULTIMODAL,
  pages:              ordered,
  totals: {
    pages:         ordered.size,
    t1_edges:      ordered.sum { |p| p[:t1_edges].size },
    t2_edges:      ordered.sum { |p| p[:t2_edges].size },
    components:    ordered.sum { |p| p[:components].size },
    input_tokens:  ordered.sum { |p| p[:input_tokens] },
    output_tokens: ordered.sum { |p| p[:output_tokens] },
    cost_usd:      ordered.sum { |p| p[:cost_usd] }.round(4)
  }
}

File.write(OUT_PATH, JSON.pretty_generate(payload))
warn "GATE B #{LABEL}: wrote #{OUT_PATH} — #{payload[:totals].to_json}"
