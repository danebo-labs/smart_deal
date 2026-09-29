# frozen_string_literal: true

# Phase 5 of docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md
# Rewrites the contradicted bornera rows of one object:
#   bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p1_2.txt
#
# Cost: zero Claude calls. One PutObject through S3DocumentsService#upload_text
# (that call runs SectionNeighborExpander.invalidate!) and one KB ingestion job.
# The bucket has no versioning.
#
# Rollback: upload the saved object back through S3DocumentsService#upload_text,
# then start the same BulkKbSyncService job. The bytes and SHA are
# tmp/elemont_patch_2026-09-28/chunk_p1_2_before.txt
# SHA 688a5d780eef8845c489af53f186d275a3a1cc7a4b35f42b38cc2d53be03776c
#
# Usage, from a checkout that contains ElemontMhSheet1BorneraPatch:
#   RAG_CHUNK_PATCH_CONFIRM=1 bin/rails runner script/patch_elemont_chunk_p1_2_bornera_2026-09-28.rb
#
# The deployed image does not contain script/ or this patch class. To run the
# write where production Solid Cache is invalidated, pipe the class and this
# file on stdin (no deploy):
#   cat app/services/elemont_mh_sheet1_bornera_patch.rb \
#       script/patch_elemont_chunk_p1_2_bornera_2026-09-28.rb \
#     | ssh ... docker exec -i -e RAG_CHUNK_PATCH_CONFIRM=1 $CID bin/rails runner -

abort("Set RAG_CHUNK_PATCH_CONFIRM=1 to run (mutates the production KB)") unless ENV["RAG_CHUNK_PATCH_CONFIRM"] == "1"

require "digest"
require "fileutils"

unless defined?(ElemontMhSheet1BorneraPatch)
  require Rails.root.join("app/services/elemont_mh_sheet1_bornera_patch")
end

ENV["KNOWLEDGE_BASE_S3_BUCKET"]    = "multimodal-source-destination"
ENV["BEDROCK_KNOWLEDGE_BASE_ID"]   = "Y7RZWMFJSR"
ENV["BEDROCK_BULK_DATA_SOURCE_ID"] = "PJ0N58DMHG"
ENV["BEDROCK_DATA_SOURCE_ID"]      = "PJ0N58DMHG"
ENV["AWS_REGION"]                  = "us-east-1"

ActiveJob::Base.queue_adapter = :inline

KEY            = "bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p1_2.txt"
SHEET2_KEY     = "bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p2_1.txt"
OUT_DIR        = Rails.root.join("tmp/elemont_patch_2026-09-28")
EXPECTED_LIVE  = "688a5d780eef8845c489af53f186d275a3a1cc7a4b35f42b38cc2d53be03776c"
EXPECTED_SHEET2 = "70fa1eafac8b2b2baa707d7941e7f1879f4c2e1a5c2fec081c9b262a52d543f6"

s3 = S3DocumentsService.new
live_binary = s3.download(KEY)
abort("Could not download #{KEY}") if live_binary.nil?

live_sha = Digest::SHA256.hexdigest(live_binary)
abort("Live object SHA mismatch (#{live_sha}); expected #{EXPECTED_LIVE}. No write.") unless live_sha == EXPECTED_LIVE

sheet2_binary = s3.download(SHEET2_KEY)
abort("Could not download #{SHEET2_KEY}") if sheet2_binary.nil?

sheet2_sha = Digest::SHA256.hexdigest(sheet2_binary)
abort("Sheet 2 SHA mismatch (#{sheet2_sha}); expected #{EXPECTED_SHEET2}. No write.") unless sheet2_sha == EXPECTED_SHEET2

sheet2 = sheet2_binary.dup.force_encoding(Encoding::UTF_8)
abort("Sheet 2 is not valid UTF-8") unless sheet2.valid_encoding?
abort("Sheet 2 no longer has the authoritative bornera rows. No write.") unless ElemontMhSheet1BorneraPatch.sheet2_authority?(sheet2)

live = live_binary.dup.force_encoding(Encoding::UTF_8)
abort("Live object is not valid UTF-8") unless live.valid_encoding?

patched = ElemontMhSheet1BorneraPatch.apply!(live)
abort("Patched body is not the same chunk outside the replaced rows") unless ElemontMhSheet1BorneraPatch.unchanged_body(live) == ElemontMhSheet1BorneraPatch.unchanged_body(patched)

patched_sha = Digest::SHA256.hexdigest(patched)
abort("Patched SHA matches the live object") if patched_sha == live_sha

FileUtils.mkdir_p(OUT_DIR)
backup_path = OUT_DIR.join("chunk_p1_2_before.txt")
File.binwrite(backup_path, live_binary)
backup_sha = Digest::SHA256.hexdigest(File.binread(backup_path))
abort("Backup SHA mismatch (#{backup_sha})") unless backup_sha == EXPECTED_LIVE
File.binwrite(OUT_DIR.join("chunk_p1_2_after.txt"), patched)

puts "=" * 80
puts "Elemont chunk_p1_2 bornera patch"
puts "  key:     #{KEY}"
puts "  before:  #{live_binary.bytesize} bytes sha #{live_sha}"
puts "  after:   #{patched.bytesize} bytes sha #{patched_sha}"
puts "  backup:  #{backup_path}"
puts "=" * 80

uploaded = s3.upload_text(KEY, patched)
abort("Upload failed") unless uploaded == KEY

roundtrip = s3.download(KEY)
abort("Round-trip download failed") if roundtrip.nil?
roundtrip_sha = Digest::SHA256.hexdigest(roundtrip)
abort("Round-trip SHA mismatch (#{roundtrip_sha})") unless roundtrip_sha == patched_sha
abort("Round-trip bytes differ") unless roundtrip.b == patched.b

roundtrip_text = roundtrip.dup.force_encoding(Encoding::UTF_8)
leftovers = ElemontMhSheet1BorneraPatch.false_assignment_lines(roundtrip_text)
abort("False assignment still readable after upload: #{leftovers.inspect}") if leftovers.any?
abort("Round-trip changed more than the replaced rows") unless ElemontMhSheet1BorneraPatch.unchanged_body(live) == ElemontMhSheet1BorneraPatch.unchanged_body(roundtrip_text)

puts "Uploaded and verified. sha #{roundtrip_sha}"

sync_result = BulkKbSyncService.new.sync!(
  uploaded_filenames: [ "Montacargas 2N Temporizado-1 (1).pdf" ],
  locale: "es"
)
abort("KB sync did not start") unless sync_result
puts "  job_id:         #{sync_result[:job_id]}"
puts "  kb_id:          #{sync_result[:kb_id]}"
puts "  data_source_id: #{sync_result[:data_source_id]}"

require "aws-sdk-bedrockagent"
agent = Aws::BedrockAgent::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
status = "STARTING"
job = nil
print "Polling ingestion job: "
90.times do
  job = agent.get_ingestion_job(
    knowledge_base_id: sync_result[:kb_id],
    data_source_id:    sync_result[:data_source_id],
    ingestion_job_id:  sync_result[:job_id]
  ).ingestion_job
  status = job.status
  print "#{status} "
  break unless %w[STARTING IN_PROGRESS].include?(status)

  sleep 10
end
puts
abort("KB ingestion job ended with status #{status}") unless status == "COMPLETE"

stats = job.statistics
if stats
  puts "  scanned=#{stats.number_of_documents_scanned.to_i} new=#{stats.number_of_new_documents_indexed.to_i} modified=#{stats.number_of_modified_documents_indexed.to_i} deleted=#{stats.number_of_documents_deleted.to_i} failed=#{stats.number_of_documents_failed.to_i}"
  abort("KB ingestion indexed failures") if stats.number_of_documents_failed.to_i.positive?
end

puts "\nRESULT: OK — chunk_p1_2 bornera patched and KB sync COMPLETE"
puts "ROLLBACK: re-upload #{backup_path} (sha #{EXPECTED_LIVE}) through S3DocumentsService#upload_text, then BulkKbSyncService"
