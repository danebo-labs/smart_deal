# frozen_string_literal: true

# Surgical identity patch for a single already-indexed chunk: page 93 of
# SEGURIDADES 1.1-1 (`chunk_91.txt`, THYSSEN SERIE E safety-chain diagram).
#
# Why: the brand token lives only on divider page 92 (`chunk_90.txt`), so the
# page-93 chunk carries no THYSSEN token at all. Any question phrased with the
# brand ("En Thyssen-E, ¿qué LED…?") never retrieves it, even though the page
# documents the L9/L8/L7 → supervised-series table. Verified against the PDF:
# page 92 is the "THYSSEN" divider (SERIE E/B/F, CMC 3/4/4+) and page 93 is
# titled "SERIE E" — the section identity assertion is visually confirmed
# (`tmp/seguridades_thyssen_2026-07-26/page-92.png`, `page-93.png`,
# `p93_led_table.png`).
#
# Scope: the `[SEARCH_ALIASES: …]` line only. The body is byte-identical, so no
# technical claim changes. Alias count stays at CHUNK_ALIAS_LIMIT (8): the two
# dropped aliases (POLEA TENSORA, CERROJOS CABINA) appear verbatim in the body,
# the brand token did not appear anywhere.
#
# Cost: zero Claude calls. PutObject on the same key + one KB ingestion job,
# which only re-embeds the changed chunk (Titan). Do NOT re-ingest the document.
#
# Idempotent: re-running after a successful patch exits without an S3 write.
#
# Rollback: re-upload
# `tmp/seguridades_thyssen_2026-07-26/chunk_91_live_backup.txt` (sha 695b8695…)
# to the same key and resync. The bucket has no versioning.
#
# Usage:
#   RAG_CHUNK_PATCH_CONFIRM=1 bin/rails runner script/patch_seguridades_thyssen_p93_2026-07-26.rb

abort("Set RAG_CHUNK_PATCH_CONFIRM=1 to run (mutates the production KB)") unless ENV["RAG_CHUNK_PATCH_CONFIRM"] == "1"

ENV["KNOWLEDGE_BASE_S3_BUCKET"]    = "multimodal-source-destination"
ENV["BEDROCK_KNOWLEDGE_BASE_ID"]   = "Y7RZWMFJSR"
ENV["BEDROCK_BULK_DATA_SOURCE_ID"] = "PJ0N58DMHG"
ENV["BEDROCK_DATA_SOURCE_ID"]      = "PJ0N58DMHG"
ENV["AWS_REGION"]                  = "us-east-1"

ActiveJob::Base.queue_adapter = :inline

KEY           = "bulk_chunks/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/chunk_91.txt"
BACKUP_PATH   = Rails.root.join("tmp/seguridades_thyssen_2026-07-26/chunk_91_live_backup.txt")
PATCHED_PATH  = Rails.root.join("tmp/seguridades_thyssen_2026-07-26/chunk_91_patched.txt")
EXPECTED_LIVE = "695b86954da9e77b30292779dc9f889357adecb5e92b94163abe5ab4c9c02e3f"
ALIAS_LINE    = /^\[SEARCH_ALIASES:[^\n]*\]$/
NEW_ALIAS_LINE = "[SEARCH_ALIASES: THYSSEN, THYSSEN-E, SERIE E, BLOQUE B, BLOQUE C, cadena de seguridades, L9 L8 L7, STOP FOSO]"
BODY_MARKERS  = [
  "## S7 — DIAGRAM: SERIE E — Cadena de Seguridades Principales",
  "| L9  | SERIE SEGURIDADES PRINCIPALES |",
  "| L8  | SERIE PUERTAS EXTERIORES |",
  "| L7  | SERIE CERROJOS EXTERIORES - CABINA |"
].freeze

s3 = S3DocumentsService.new
live = s3.download(KEY)
abort("Could not download #{KEY}") if live.nil?

live_text = live.dup.force_encoding(Encoding::UTF_8)
live_sha  = Digest::SHA256.hexdigest(live)

if live_text.match?(/^\[SEARCH_ALIASES:[^\n]*THYSSEN/)
  puts "Already patched (alias line carries THYSSEN); nothing to do."
  exit 0
end

abort("Live object SHA mismatch (#{live_sha}) — someone changed it, re-verify before patching") unless live_sha == EXPECTED_LIVE

sidecar = s3.download("#{KEY}.metadata.json").to_s
abort("Sidecar does not report page_number 93") unless sidecar.include?('"page_number":93')

missing = BODY_MARKERS.reject { |marker| live_text.include?(marker) }
abort("Live chunk is not the page-93 SERIE E diagram (missing: #{missing.inspect})") if missing.any?

alias_matches = live_text.scan(ALIAS_LINE)
abort("Expected exactly one alias line, found #{alias_matches.size}") unless alias_matches.size == 1

patched = live_text.sub(ALIAS_LINE, NEW_ALIAS_LINE)
abort("Patched content is identical to live — nothing to do") if patched == live_text

live_body    = live_text.sub(ALIAS_LINE, "")
patched_body = patched.sub(ALIAS_LINE, "")
abort("Body changed — the patch must only touch the alias line") unless live_body == patched_body

FileUtils.mkdir_p(File.dirname(BACKUP_PATH))
File.binwrite(BACKUP_PATH, live)
File.write(PATCHED_PATH, patched)

puts "=" * 80
puts "SEGURIDADES chunk_91 (page 93) THYSSEN alias patch"
puts "  bucket:   #{s3.bucket_name}"
puts "  key:      #{KEY}"
puts "  live:     #{live.bytesize} bytes (sha #{live_sha[0, 12]})"
puts "  patched:  #{patched.bytesize} bytes (sha #{Digest::SHA256.hexdigest(patched)[0, 12]})"
puts "  backup:   #{BACKUP_PATH}"
puts "=" * 80

abort("Upload failed") unless s3.upload_text(KEY, patched)

roundtrip = s3.download(KEY)
abort("Round-trip verification failed") unless roundtrip == patched.dup.force_encoding(Encoding::BINARY)
puts "Uploaded and verified."

sync_result = BulkKbSyncService.new.sync!(uploaded_filenames: [ "SEGURIDADES 1.1-1.pdf" ], locale: "es")
abort("KB sync did not start") unless sync_result
puts "  job_id:         #{sync_result[:job_id]}"
puts "  kb_id:          #{sync_result[:kb_id]}"
puts "  data_source_id: #{sync_result[:data_source_id]}"

require "aws-sdk-bedrockagent"
agent = Aws::BedrockAgent::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
status = "STARTING"
print "Polling ingestion job: "
90.times do
  status = agent.get_ingestion_job(
    knowledge_base_id: sync_result[:kb_id],
    data_source_id:    sync_result[:data_source_id],
    ingestion_job_id:  sync_result[:job_id]
  ).ingestion_job.status
  print "#{status} "
  break unless %w[STARTING IN_PROGRESS].include?(status)

  sleep 10
end
puts

abort("KB ingestion job ended with status #{status}") unless status == "COMPLETE"
puts "\nRESULT: OK — chunk_91 alias line patched and KB sync COMPLETE"
