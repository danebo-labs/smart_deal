# frozen_string_literal: true

# Surgical alias patch for a single already-indexed chunk: page 25 of
# SEGURIDADES 1.1-1 (`chunk_23.txt`, EDEL-K2 board connection diagram).
#
# Why: pilot rubric case `edel_k2_led31` ("En EDEL-K2, ¿qué indica el LED 31…?")
# never reaches page 25. Measured against the production KB on 2026-07-28 with
# the pilot question and the profile's `top_k = 3`:
#
#   #1 chunk_24 (p26, EDEL-K3)   #2 chunk_44 (p46, EKM 1000)   #3 chunk_21 (p23, EDEL divider)
#   #5 chunk_23 (p25, EDEL-K2)   <- the only page that documents LED 31
#
# The chunk IS indexed and IS retrievable — the same query written as keywords
# ("EDEL-K2 LED 31 REAPERTURA") returns it at #1 with an RRF score of 0.99, i.e.
# it tops both the lexical and the semantic list. On the natural-language
# phrasing it drops to rank 5, so the LED/serie binding never enters the
# generation context. Widening `top_k` is closed (measured regressive, guarded by
# `test/services/rag_retrieval_profile_test.rb`), so the sanctioned lever is the
# alias line, exactly as in `script/patch_seguridades_thyssen_p93_2026-07-26.rb`.
#
# Verified against the PDF, not against marker's `.md`
# (`tmp/seguridades_edel_k2_2026-07-28/page-25.png`): the page is titled
# "EDEL-K2", its LED table prints `31 | REAPERTURA`, and it documents no
# on/off conditions for any LED. The chunk body already reproduces this
# correctly, so there is no content defect to patch — only retrievability.
#
# Scope: the `[SEARCH_ALIASES: …]` line only. The body is byte-identical, so no
# technical claim changes. Alias count stays at CHUNK_ALIAS_LIMIT (8):
#   - dropped `polea tensora` — appears verbatim in the body (4 times).
#   - dropped `sonda termica` — superseded by the richer `LED 32 SONDA TERMICA`,
#     so LED 32 keeps its alias coverage instead of losing it to this patch.
#   - added `LED 31 REAPERTURA` (the retrieval gap) and `LED 32 SONDA TERMICA`.
#
# Cost: zero Claude calls. PutObject on the same key + one KB ingestion job,
# which only re-embeds the changed chunk (Titan). Do NOT re-ingest the document.
#
# Idempotent: re-running after a successful patch exits without an S3 write.
#
# Rollback: re-upload
# `tmp/seguridades_edel_k2_2026-07-28/chunk_23_live_backup.txt` (sha 36cc94e3…)
# to the same key and resync. The bucket has no versioning.
#
# Note: this patch alone cannot make `edel_k2_led31` pass. The question is also
# misrouted — `Rag::DeterministicIntent::EXPLICIT_EQUIPMENT_PATTERN` requires a
# digit right after the letters (`EDEL-542` matches, `EDEL-K2` does not), so the
# question is classified as an ambiguous hardware query and answered by
# `Rag::AmbiguousModelResponder` instead of the generative path. That is a
# separate Rails fix; this patch only puts page 25 inside `top_k = 3`.
#
# Usage:
#   RAG_CHUNK_PATCH_CONFIRM=1 bin/rails runner script/patch_seguridades_edel_k2_p25_2026-07-28.rb

abort("Set RAG_CHUNK_PATCH_CONFIRM=1 to run (mutates the production KB)") unless ENV["RAG_CHUNK_PATCH_CONFIRM"] == "1"

ENV["KNOWLEDGE_BASE_S3_BUCKET"]    = "multimodal-source-destination"
ENV["BEDROCK_KNOWLEDGE_BASE_ID"]   = "Y7RZWMFJSR"
ENV["BEDROCK_BULK_DATA_SOURCE_ID"] = "PJ0N58DMHG"
ENV["BEDROCK_DATA_SOURCE_ID"]      = "PJ0N58DMHG"
ENV["AWS_REGION"]                  = "us-east-1"

ActiveJob::Base.queue_adapter = :inline

KEY           = "bulk_chunks/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/chunk_23.txt"
BACKUP_PATH   = Rails.root.join("tmp/seguridades_edel_k2_2026-07-28/chunk_23_live_backup.txt")
PATCHED_PATH  = Rails.root.join("tmp/seguridades_edel_k2_2026-07-28/chunk_23_patched.txt")
EXPECTED_LIVE = "36cc94e38f3723259edf2956645a19fd06a9afe1771abb062dfaa0e10746477a"
ALIAS_LINE    = /^\[SEARCH_ALIASES:[^\n]*\]$/
NEW_ALIAS_LINE = "[SEARCH_ALIASES: EDEL-K2, edel k2, LED 31 REAPERTURA, LED 32 SONDA TERMICA, " \
                 "serie seguridades, tension series, C1 C2 H2 M1, fotocelula embarque]"
BODY_MARKERS  = [
  "## S7 — DIAGRAM: EDEL-K2 Board Connection Overview",
  "| 31  | REAPERTURA |",
  "| 32  | SONDA TERMICA |",
  "ACTION: LED 31 — REAPERTURA"
].freeze

s3 = S3DocumentsService.new
live = s3.download(KEY)
abort("Could not download #{KEY}") if live.nil?

live_text = live.dup.force_encoding(Encoding::UTF_8)
live_sha  = Digest::SHA256.hexdigest(live)

if live_text.match?(/^\[SEARCH_ALIASES:[^\n]*LED 31 REAPERTURA/)
  puts "Already patched (alias line carries LED 31 REAPERTURA); nothing to do."
  exit 0
end

abort("Live object SHA mismatch (#{live_sha}) — someone changed it, re-verify before patching") unless live_sha == EXPECTED_LIVE

sidecar = s3.download("#{KEY}.metadata.json").to_s
abort("Sidecar does not report page_number 25") unless sidecar.include?('"page_number":25')

missing = BODY_MARKERS.reject { |marker| live_text.include?(marker) }
abort("Live chunk is not the page-25 EDEL-K2 diagram (missing: #{missing.inspect})") if missing.any?

alias_matches = live_text.scan(ALIAS_LINE)
abort("Expected exactly one alias line, found #{alias_matches.size}") unless alias_matches.size == 1

abort("New alias line exceeds CHUNK_ALIAS_LIMIT") unless
  NEW_ALIAS_LINE.delete_prefix("[SEARCH_ALIASES:").delete_suffix("]").split(",").size <= ChunkMergerService::CHUNK_ALIAS_LIMIT

patched = live_text.sub(ALIAS_LINE, NEW_ALIAS_LINE)
abort("Patched content is identical to live — nothing to do") if patched == live_text

live_body    = live_text.sub(ALIAS_LINE, "")
patched_body = patched.sub(ALIAS_LINE, "")
abort("Body changed — the patch must only touch the alias line") unless live_body == patched_body

FileUtils.mkdir_p(File.dirname(BACKUP_PATH))
File.binwrite(BACKUP_PATH, live)
File.write(PATCHED_PATH, patched)

puts "=" * 80
puts "SEGURIDADES chunk_23 (page 25) EDEL-K2 LED 31 alias patch"
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
puts "\nRESULT: OK — chunk_23 alias line patched and KB sync COMPLETE"
