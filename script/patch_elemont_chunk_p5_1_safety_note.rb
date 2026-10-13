# frozen_string_literal: true

# Writes one object when RAG_PAGE5_SAFETY_NOTE_CONFIRM=1:
#   bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p5_1.txt
#
# 40b9dc4 allowed this preparation. It did not allow the write. Do not run
# this file from the preparation commit.
#
# Target, exact: bucket multimodal-source-destination, knowledge base
# Y7RZWMFJSR, data source PJ0N58DMHG, region us-east-1. The comment in
# BatchChunkingPrompt that names 8DUTRUCDTS is not this data source.
# The shared sync entry point falls back to the first listed data source
# when the requested id is missing, so this script does not call it. The
# agent client receives PJ0N58DMHG only after list_data_sources contains it.
#
# The job adapter is left as the process found it. The 2026-09-28 bornera
# script forced every later perform_later to run in process. This script
# does not enqueue.
#
# The downloaded body is backed up before the upload. Its SHA is the live
# SHA. The capture SHA 8baae756… is the body without a trailing newline
# and is not a gate. The sidecar is read before and after the text upload
# and is not written.
#
# Sync: start_ingestion_job, then get_ingestion_job until the job leaves
# STARTING / IN_PROGRESS, or 90 observations. COMPLETE with a failed count
# of 0 and a positive modified count is the check. Any other finished
# status restores the backup body and starts one ingestion of that body on
# the same data source. A job still running at the poll limit does not
# start a second job; the backup stays in
# tmp/elemont_page5_safety_note/<utc>/.
#
# Rollback by hand: upload chunk_p5_1_before.bin through
# S3DocumentsService#upload_text at the same key, then start_ingestion_job
# on PJ0N58DMHG. Do not upload the sidecar backup.

abort("Set RAG_PAGE5_SAFETY_NOTE_CONFIRM=1 to run (mutates the production KB)") unless ENV["RAG_PAGE5_SAFETY_NOTE_CONFIRM"] == "1"

require "aws-sdk-bedrockagent"
require "fileutils"

require Rails.root.join("app/services/elemont_mh_page5_safety_note_patch")
require Rails.root.join("app/services/elemont_mh_page5_safety_note_repair")

patch = ElemontMhPage5SafetyNotePatch
ENV["AWS_REGION"] = patch::REGION
ENV["KNOWLEDGE_BASE_S3_BUCKET"] = patch::BUCKET

backup_dir = Rails.root.join("tmp/elemont_page5_safety_note", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
s3 = S3DocumentsService.new(bucket_name: patch::BUCKET)
agent = Aws::BedrockAgent::Client.new(region: patch::REGION)

repair = ElemontMhPage5SafetyNoteRepair.new(
  s3: s3,
  agent: agent,
  bucket: patch::BUCKET,
  knowledge_base_id: patch::KNOWLEDGE_BASE_ID,
  data_source_id: patch::DATA_SOURCE_ID,
  backup_dir: backup_dir,
  confirm: ENV["RAG_PAGE5_SAFETY_NOTE_CONFIRM"]
)

begin
  patched = repair.call
rescue ElemontMhPage5SafetyNoteRepair::Stop => e
  abort(e.message)
end

puts "uploaded #{patch::KEY}"
puts "patched_sha256=#{patch.digest(patched)}"
puts "backup=#{backup_dir}"
puts "ingestions=#{repair.ingestions.inspect}"
