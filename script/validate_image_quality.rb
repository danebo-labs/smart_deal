# frozen_string_literal: true

# Usage: bin/rails runner script/validate_image_quality.rb path/to/img1.jpg [path/to/img2.jpg ...]
#
# Compara la calidad de extracción Claude Opus a JPEG q=82 vs q=92 (ambos maxDim=1024).
# - No toca BD, S3, ni Solid Queue.
# - Usa BatchChunkingPrompt::SYSTEM_BLOCKS (mismo cache que prod).
# - Aleatoriza orden por imagen para neutralizar sesgo de prompt caching.
# - Reporta cost_fair (sin cache) + cost_total + Δoutput_tokens.

require "vips"

QUALITIES = [ 0.82, 0.92 ]
MAX_DIM   = 1024
MODEL     = BatchChunkingPrompt::MODEL_MULTIMODAL  # "claude-opus-4-7"

# $/1k tokens (Opus 4.x). Dividir por 1000 al final.
OPUS_PRICING = { input: 0.015, output: 0.075, cache_create: 0.01875, cache_read: 0.0015 }

def compress(path, quality_float)
  q = (quality_float * 100).round
  img = Vips::Image.new_from_file(path).thumbnail_image(MAX_DIM, size: :down)
  img.write_to_buffer(".jpg[Q=#{q}]")
end

def call_claude(client, jpeg_bytes, filename)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  msg = client.messages.stream(
    model:      MODEL,
    max_tokens: BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
    system:     BatchChunkingPrompt::SYSTEM_BLOCKS,
    messages: [ { role: "user", content: BatchChunkingPrompt.user_content(
      binary: jpeg_bytes, content_type: "image/jpeg", filename: filename, locale: "es"
    ) } ]
  ).accumulated_message
  ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

  text   = msg.content.find { |b| b.type.to_s == "text" }&.text.to_s
  parsed = JSON.parse(text) rescue { "aliases" => [], "chunks" => [], "summary" => "(parse failed)" }

  {
    input:       msg.usage.input_tokens.to_i,
    output:      msg.usage.output_tokens.to_i,
    cache_c:     msg.usage.respond_to?(:cache_creation_input_tokens) ? msg.usage.cache_creation_input_tokens.to_i : 0,
    cache_r:     msg.usage.respond_to?(:cache_read_input_tokens)     ? msg.usage.cache_read_input_tokens.to_i     : 0,
    aliases:     parsed["aliases"] || [],
    chunks_n:    (parsed["chunks"] || []).size,
    summary:     (parsed["summary"] || "").to_s[0, 140],
    stop_reason: msg.respond_to?(:stop_reason) ? msg.stop_reason.to_s : nil,
    latency_ms:  ms
  }
end

def cost_total(r)
  (r[:input]   * OPUS_PRICING[:input]        +
   r[:output]  * OPUS_PRICING[:output]       +
   r[:cache_c] * OPUS_PRICING[:cache_create] +
   r[:cache_r] * OPUS_PRICING[:cache_read]) / 1000.0
end

# "fair" = costo si la imagen se procesara en frío (sin beneficio de cache_read del system).
# Es lo que el agregado de prod va a pagar a la larga: input regular + output regular.
def cost_fair(r)
  (r[:input] * OPUS_PRICING[:input] + r[:output] * OPUS_PRICING[:output]) / 1000.0
end

def normalize_alias(a)
  a.to_s.downcase.gsub(/[\s\-_]+/, " ").strip
end

def alias_diff(a_list, b_list)
  b_set = b_list.map { |a| normalize_alias(a) }.to_set
  a_list.reject { |a| b_set.include?(normalize_alias(a)) }
end

client = Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))

ARGV.each do |path|
  abort "missing: #{path}" unless File.exist?(path)

  orig = Vips::Image.new_from_file(path)
  puts "\n=== #{File.basename(path)} (original #{orig.width}x#{orig.height}, #{File.size(path) / 1024} KB) ==="

  # Aleatorizar orden por imagen para neutralizar sesgo de prompt caching.
  qualities_this_image = QUALITIES.shuffle
  puts "  call order: #{qualities_this_image.inspect}"

  by_quality = {}
  qualities_this_image.each do |q|
    jpeg = compress(path, q)
    res  = call_claude(client, jpeg, File.basename(path))
    by_quality[q] = res.merge(quality: q, jpeg_kb: jpeg.bytesize / 1024)
  end

  # Imprimir resultados en orden canónico (siempre q=0.82 primero, luego q=0.92) para legibilidad.
  results = QUALITIES.map { |q| by_quality.fetch(q) }

  results.each do |r|
    printf "  q=%.2f (1024px, %3d KB) -> in:%4d out:%4d cc:%4d cr:%4d aliases:%2d chunks:%2d cost_total:$%.4f cost_fair:$%.4f lat:%ds stop:%s\n",
      r[:quality], r[:jpeg_kb], r[:input], r[:output], r[:cache_c], r[:cache_r],
      r[:aliases].size, r[:chunks_n], cost_total(r), cost_fair(r),
      (r[:latency_ms] / 1000.0).round, r[:stop_reason].to_s[0, 10]
    puts "    summary: #{r[:summary]}"
    puts "    aliases: #{r[:aliases].first(8).inspect}"
  end

  q82, q92 = results
  delta_output = q92[:output] - q82[:output]
  delta_fair   = cost_fair(q92) - cost_fair(q82)
  new_aliases  = alias_diff(q92[:aliases], q82[:aliases])
  lost_aliases = alias_diff(q82[:aliases], q92[:aliases])

  puts "\n  DELTA q=0.92 vs q=0.82 (lo que decide producción):"
  puts "    Δoutput_tokens: #{delta_output >= 0 ? '+' : ''}#{delta_output} (costo Bedrock marginal real)"
  puts "    Δcost_fair:     #{delta_fair >= 0 ? '+' : ''}$#{format('%.4f', delta_fair)} " \
       "(#{q82[:input] == 0 ? 'n/a' : "#{((delta_fair / cost_fair(q82)) * 100).round(1)}%"})"
  puts "    aliases:        +#{new_aliases.size} new (#{new_aliases.first(6).inspect}) / " \
       "-#{lost_aliases.size} lost (#{lost_aliases.first(3).inspect})"
  puts "    chunks:         #{q82[:chunks_n]} -> #{q92[:chunks_n]}"
  if q82[:stop_reason] == "max_tokens" || q92[:stop_reason] == "max_tokens"
    puts "    WARN: alguna call truncó al cap de 4000 tokens — comparación de output no es confiable"
  end
end
