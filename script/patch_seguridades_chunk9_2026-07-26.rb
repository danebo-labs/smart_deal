# frozen_string_literal: true

# Surgical content patch for a single already-indexed chunk: page 11 of
# SEGURIDADES 1.1-1 (HIDRA-TPR70 connector topology). The field_records_v5
# ingestion assigned one component per numbered terminal on B7/B8, but the
# scanned diagram wires several terminals to a single shared series chain or to
# one 2-pole device. That produced a verified hallucination ("EPC ... conector
# B8, terminal 5") on a safety-critical claim.
#
# Cost: zero Claude calls. PutObject on the same key + one KB ingestion job,
# which only re-embeds the changed chunk (Titan). Do NOT re-ingest the whole
# document — see /Users/lahirisan/.cursor/plans/precisión_definitiva_rag_seguridades_d017baca.plan.md
#
# Rollback: re-upload tmp/seguridades_reingest_2026-07-25/chunk_9_current.txt
# (the bucket has no versioning; backup_chunks/ holds the pre-25-jul objects).
#
# Usage:
#   RAG_CHUNK_PATCH_CONFIRM=1 bin/rails runner script/patch_seguridades_chunk9_2026-07-26.rb

abort("Set RAG_CHUNK_PATCH_CONFIRM=1 to run (mutates the production KB)") unless ENV["RAG_CHUNK_PATCH_CONFIRM"] == "1"

ENV["KNOWLEDGE_BASE_S3_BUCKET"]    = "multimodal-source-destination"
ENV["BEDROCK_KNOWLEDGE_BASE_ID"]   = "Y7RZWMFJSR"
ENV["BEDROCK_BULK_DATA_SOURCE_ID"] = "PJ0N58DMHG"
ENV["BEDROCK_DATA_SOURCE_ID"]      = "PJ0N58DMHG"
ENV["AWS_REGION"]                  = "us-east-1"

ActiveJob::Base.queue_adapter = :inline

KEY           = "bulk_chunks/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/chunk_9.txt"
CURRENT_PATH  = Rails.root.join("tmp/seguridades_reingest_2026-07-25/chunk_9_current.txt")
PATCHED_PATH  = Rails.root.join("tmp/seguridades_reingest_2026-07-25/chunk_9_corrected.txt")
EXPECTED_LIVE = "f9a93d973781d55e7820c253787973fcdb82821da362a09191a2dd9f70a12f86"

s3 = S3DocumentsService.new
live = s3.download(KEY)
abort("Could not download #{KEY}") if live.nil?

live_sha = Digest::SHA256.hexdigest(live)
abort("Live object SHA mismatch (#{live_sha}) — someone changed it, re-verify before patching") unless live_sha == EXPECTED_LIVE
abort("Live object differs from #{CURRENT_PATH}") unless live == File.binread(CURRENT_PATH)

patched = File.read(PATCHED_PATH)
abort("Patched content is identical to live — nothing to do") if patched == live

puts "=" * 80
puts "SEGURIDADES chunk_9 topology patch"
puts "  bucket:   #{s3.bucket_name}"
puts "  key:      #{KEY}"
puts "  live:     #{live.bytesize} bytes (sha #{live_sha[0, 12]})"
puts "  patched:  #{patched.bytesize} bytes (sha #{Digest::SHA256.hexdigest(patched)[0, 12]})"
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
puts "\nRESULT: OK — chunk_9 patched and KB sync COMPLETE"
