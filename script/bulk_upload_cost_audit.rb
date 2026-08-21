# frozen_string_literal: true

# Measures the real Anthropic cost of a bulk ZIP ingestion from the
# `bedrock_queries` rows that IngestBatchResultsJob writes per page.
#
#   BULK_UPLOAD_ID=3 bin/rails runner script/bulk_upload_cost_audit.rb
#
# Read-only. Makes no API calls: every token figure already lives in the DB,
# including the cache read/write tokens that `bulk_upload_assets` folds into
# `claude_input_tokens` and therefore cannot price separately.
#
# Rows are matched by time window and then filtered to this upload's own asset
# filenames, so a concurrent upload in the same window cannot leak into the total.

id = ENV.fetch("BULK_UPLOAD_ID") { abort("set BULK_UPLOAD_ID") }.to_i
bu = BulkUpload.find(id)

assets     = bu.bulk_upload_assets.pluck(:filename, :status, :claude_input_tokens, :claude_output_tokens)
filenames  = assets.map(&:first).to_set
by_status  = assets.group_by { |a| a[1] }.transform_values(&:size)

# IngestBatchResultsJob labels: "bulk_batch: <filename> pN/M" (PDF pages),
# "bulk_parse: <filename>" (images).
window = (bu.created_at - 5.minutes)..(bu.updated_at + 6.hours)
rows   = BedrockQuery
  .where(route: "batch", created_at: window)
  .where("user_query LIKE 'bulk_batch: %' OR user_query LIKE 'bulk_parse: %'")
  .pluck(:user_query, :model_id, :input_tokens, :output_tokens, :cache_read_tokens, :cache_creation_tokens)

def filename_of(label)
  label.sub(/\Abulk_(batch|parse): /, "").sub(%r{ p\d+/\d+\z}, "")
end

mine, foreign = rows.partition { |r| filenames.include?(filename_of(r[0])) }

def price(model, toks)
  BedrockQuery.new(
    model_id: model,
    input_tokens: toks[:input], output_tokens: toks[:output],
    cache_read_tokens: toks[:cache_read], cache_creation_tokens: toks[:cache_creation]
  ).cost
end

blank = { input: 0, output: 0, cache_read: 0, cache_creation: 0, pages: 0 }
per_model = Hash.new { |h, k| h[k] = blank.dup }
per_file  = Hash.new { |h, k| h[k] = Hash.new { |g, m| g[m] = blank.dup } }

mine.each do |label, model, inp, out, cr, cc|
  acc = { input: inp.to_i, output: out.to_i, cache_read: cr.to_i, cache_creation: cc.to_i }
  file = filename_of(label)
  [ per_model[model], per_file[file][model] ].each do |bucket|
    acc.each { |k, v| bucket[k] += v }
    bucket[:pages] += 1
  end
end

total_cost  = per_model.sum { |model, t| price(model, t) }
total_pages = per_model.sum { |_, t| t[:pages] }

puts "=" * 78
puts "BulkUpload #{bu.id}  #{bu.original_filename}"
puts "  status        #{bu.status}#{bu.error_message.present? ? "  (#{bu.error_message})" : ''}"
puts "  account       #{bu.account_id.inspect}  user #{bu.user&.email}"
puts "  created       #{bu.created_at}   updated #{bu.updated_at}"
puts "  assets        #{by_status.sort.map { |s, n| "#{s}=#{n}" }.join('  ')}  (#{assets.size} total)"
puts "  batches       #{bu.processing_batch_ids.size}"
puts "=" * 78

if mine.empty?
  puts "\nNo priced batch rows matched this upload in #{window}."
  puts "Rows in window belonging to other uploads: #{foreign.size}"
  exit 0
end

puts "\nREAL COST BY MODEL (Anthropic batch pricing, per 1K tokens)"
puts format("%-26s %7s %11s %11s %11s %11s %10s %9s",
            "model", "pages", "input", "output", "cache_read", "cache_wr", "USD", "USD/pg")
per_model.sort_by { |_, t| -t[:pages] }.each do |model, t|
  c = price(model, t)
  puts format("%-26s %7d %11d %11d %11d %11d %10.4f %9.4f",
              model, t[:pages], t[:input], t[:output], t[:cache_read], t[:cache_creation],
              c, c / t[:pages])
end
puts format("%-26s %7d %47s %10.4f %9.4f", "TOTAL", total_pages, "", total_cost, total_cost / total_pages)

opus = per_model.select { |m, _| m.include?("opus") }.sum { |_, t| t[:pages] }
puts format("\nOpus share: %d/%d pages (%.1f%%) — Opus is the cost driver, ~2x Sonnet per page.",
            opus, total_pages, 100.0 * opus / total_pages)

puts "\nTOP 15 FILES BY COST"
puts format("%-52s %6s %10s %9s", "file", "pages", "USD", "USD/pg")
per_file.map { |f, models|
  c = models.sum { |m, t| price(m, t) }
  [ f, models.sum { |_, t| t[:pages] }, c ]
}.sort_by { |r| -r[2] }.first(15).each do |f, pages, c|
  puts format("%-52s %6d %10.4f %9.4f", f.truncate(50), pages, c, c / pages)
end

puts "\nCross-check vs bulk_upload_assets counters (these exclude cache pricing):"
puts "  assets claude_input_tokens  #{assets.sum { |a| a[2].to_i }}"
puts "  assets claude_output_tokens #{assets.sum { |a| a[3].to_i }}"
puts "  bedrock_queries rows        #{mine.size} matched, #{foreign.size} in window from other uploads"
puts format("\nRESULT: %s cost US$%.4f over %d pages billed = US$%.4f/page",
            bu.original_filename, total_cost, total_pages, total_cost / total_pages)
