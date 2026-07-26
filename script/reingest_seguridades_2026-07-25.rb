# frozen_string_literal: true

# Re-ingests SEGURIDADES 1.1-1 against PRODUCTION S3 + the production Knowledge
# Base, reusing the existing KbDocument identity (account_id + document_uid) so
# no duplicate document is created. This is the F5 "re-ingesta" step of
# /Users/lahirisan/.cursor/plans/precisión_quirúrgica_rag_citas_55e8379c.plan.md.
#
# What changed since the original ingestion (contract field_records_v4):
#   - PageRelevanceFilter keeps brand/section divider pages that were previously
#     dropped as "section divider"/"index" (section_identity_guard?).
#   - ChunkMergerService never discards the only chunk of a page.
#   - Document identity falls back to the filename when pages disagree on
#     document_name (multi-brand compendium — document_name_consensus: false).
#   - Ingestion contract bumped to field_records_v5 (component—voltage pairing).
#
# Safety:
#   - A full backup of the current chunks/sidecars was taken to
#     tmp/seguridades_reingest_2026-07-25/backup_chunks/ before this script
#     deletes anything (the S3 bucket has no versioning).
#   - The original PDF's SHA-256 is pinned below and asserted before any write.
#   - Requires RAG_REINGEST_CONFIRM=1 (paid Anthropic calls + prod KB mutation).
#
# Usage:
#   RAG_REINGEST_CONFIRM=1 bin/rails runner script/reingest_seguridades_2026-07-25.rb

abort("Set RAG_REINGEST_CONFIRM=1 to run (paid Anthropic calls + mutates the production KB)") unless ENV["RAG_REINGEST_CONFIRM"] == "1"

# Point every ENV-driven lookup (S3DocumentsService, KbSyncService,
# BedrockRagService) at the production bucket/KB/data source for this process
# only — .env keeps pointing at the dev KB for normal local development.
ENV["KNOWLEDGE_BASE_S3_BUCKET"]    = "multimodal-source-destination"
ENV["BEDROCK_KNOWLEDGE_BASE_ID"]   = "Y7RZWMFJSR"
ENV["BEDROCK_BULK_DATA_SOURCE_ID"] = "PJ0N58DMHG"
ENV["BEDROCK_DATA_SOURCE_ID"]      = "PJ0N58DMHG"
ENV["AWS_REGION"]                  = "us-east-1"

# Tracking jobs (TrackBedrockQueryJob) run inline — no worker process attached
# to this one-off runner.
ActiveJob::Base.queue_adapter = :inline

ACCOUNT_ID     = 1
DOCUMENT_UID   = "b61f5d54-ff42-414a-97b7-01682d16f4b5"
S3_KEY         = "uploads/#{ACCOUNT_ID}/#{DOCUMENT_UID}/original.pdf"
FILENAME       = "SEGURIDADES 1.1-1.pdf"
EXPECTED_SHA   = "1843b13d81ae8756fef7dcbda72d287790a79e656472b6716e9752d9474496d1"
LOCAL_PDF_PATH = Rails.root.join("tmp/seguridades_reingest_2026-07-25/original.pdf")
CHUNK_PREFIX   = "bulk_chunks/#{ACCOUNT_ID}/#{DOCUMENT_UID}"

abort("Local PDF not found at #{LOCAL_PDF_PATH} — download it first") unless File.exist?(LOCAL_PDF_PATH)

binary = File.binread(LOCAL_PDF_PATH)
sha256 = Digest::SHA256.hexdigest(binary)
abort("SHA-256 mismatch: expected #{EXPECTED_SHA}, got #{sha256}") unless sha256 == EXPECTED_SHA

s3 = S3DocumentsService.new
puts "=" * 80
puts "SEGURIDADES 1.1-1 re-ingestion — production"
puts "  KB id:          #{ENV['BEDROCK_KNOWLEDGE_BASE_ID']}"
puts "  data source id: #{ENV['BEDROCK_BULK_DATA_SOURCE_ID']}"
puts "  bucket:         #{s3.bucket_name}"
puts "  account_id:     #{ACCOUNT_ID}"
puts "  document_uid:   #{DOCUMENT_UID}"
puts "  s3_key:         #{S3_KEY}"
puts "  sha256:         #{sha256} (verified against production sidecar)"
puts "  size:           #{binary.bytesize} bytes"
puts "  contract:       #{BatchChunkingPrompt::INGESTION_CONTRACT_VERSION}"
puts "=" * 80

existing = s3.instance_variable_get(:@s3).list_objects_v2(bucket: s3.bucket_name, prefix: CHUNK_PREFIX)
existing_count = existing.flat_map { |page| Array(page.contents) }.size
puts "Existing chunk objects under #{CHUNK_PREFIX}/: #{existing_count} (backed up locally before this run)"

deleted = s3.delete_prefix(CHUNK_PREFIX)
puts "Deleted #{deleted} previous chunk object(s)"

verify = s3.instance_variable_get(:@s3).list_objects_v2(bucket: s3.bucket_name, prefix: CHUNK_PREFIX)
remaining = verify.flat_map { |page| Array(page.contents) }.size
abort("Prefix not empty after delete (#{remaining} objects remain) — aborting before re-parse") if remaining.positive?

puts "\nRe-parsing #{FILENAME} (this makes per-page Anthropic calls; ~98 pages)…"
started_at = Time.current

asset = SingleFileChunkingService.new(
  binary:       binary,
  content_type: "application/pdf",
  filename:     FILENAME,
  s3_key:       S3_KEY,
  sha256:       sha256,
  locale:       "es",
  account_id:   ACCOUNT_ID,
  document_uid: DOCUMENT_UID
).call

elapsed = (Time.current - started_at).round(1)
puts "\nParse complete in #{elapsed}s"
puts "  canonical_name:   #{asset.canonical_name}"
puts "  aliases:          #{Array(asset.aliases).inspect}"
puts "  chunks_count:     #{asset.chunks_count}"
puts "  chunks_s3_prefix: #{asset.chunks_s3_prefix}"
puts "  degraded_pages:   #{Array(asset.degraded_pages).inspect}"

abort("Degraded pages present: #{Array(asset.degraded_pages).inspect} — inspect before syncing the KB") if Array(asset.degraded_pages).any?

sidecar = JSON.parse(s3.download("#{asset.chunks_s3_prefix}/chunk_p10_1.txt.metadata.json") || s3.download("#{asset.chunks_s3_prefix}/chunk_0.txt.metadata.json")).fetch("metadataAttributes")
puts "\nSample sidecar (p10 or chunk_0):"
puts "  canonical_name:             #{sidecar['canonical_name']}"
puts "  ingestion_contract_version: #{sidecar['ingestion_contract_version']}"
puts "  page_number:                #{sidecar['page_number']}"

new_objects = s3.instance_variable_get(:@s3).list_objects_v2(bucket: s3.bucket_name, prefix: CHUNK_PREFIX)
new_count = new_objects.flat_map { |page| Array(page.contents) }.size
puts "\nNew chunk objects under #{CHUNK_PREFIX}/: #{new_count} (was #{existing_count})"

puts "\nStarting Bedrock KB sync…"
sync_result = BulkKbSyncService.new.sync!(uploaded_filenames: [ asset.canonical_name.to_s ], locale: "es")
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

if status == "COMPLETE"
  puts "\nRESULT: OK — SEGURIDADES 1.1-1 re-ingested under #{BatchChunkingPrompt::INGESTION_CONTRACT_VERSION} and KB sync COMPLETE"
else
  abort("KB ingestion job ended with status #{status}")
end
