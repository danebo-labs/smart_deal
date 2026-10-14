# frozen_string_literal: true

# Writes one object when RAG_PAGE5_BOTONERA_BRANCH_CONFIRM=1:
#   bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p5_1.txt
#
# Preparing this file does not authorize the write. Do not run it until a
# later authorization names this script. RAG_PAGE5_SAFETY_NOTE_CONFIRM does
# not authorize it. This script does not call
# script/patch_elemont_chunk_p5_1_safety_note.rb.
#
# Target, exact: bucket multimodal-source-destination, knowledge base
# Y7RZWMFJSR, data source PJ0N58DMHG, region us-east-1. The comment in
# BatchChunkingPrompt that names 8DUTRUCDTS is not this data source.
# The shared sync entry point falls back to the first listed data source
# when the requested id is missing, so this script does not call it. The
# agent client receives PJ0N58DMHG only after list_data_sources contains it.
#
# The job adapter is left as the process found it. This script does not
# enqueue.
#
# The live core must be the safety-line body, SHA-256
# 067ff45ffa86a6d055cedbec8f38ce63ae36c5ba15266d32a48da5ccea9c6831, with at
# most one trailing newline. The upload must be the approved candidate,
# SHA-256 a13141fe7586c9013d698aa29f2b6809f112702e98f4da99d9a47c3ba01d7779,
# with that same newline. The downloaded body and sidecar are backed up
# first. The manifest in tmp/elemont_page5_botonera_branch/<utc>/ records
# those hashes, the expected base, the candidate SHA and each job id,
# initial or rollback, as soon as it is received. The sidecar is read
# before and after the text upload and is not written.
#
# Sync: start_ingestion_job, then get_ingestion_job until the job leaves
# STARTING / IN_PROGRESS, or 90 observations. COMPLETE, nothing failed and
# a positive modified count keeps the new body. COMPLETE with a positive
# modified count whose failure reasons name only other
# bulk_chunks/<account>/<sha>/chunk_pN_M.txt documents also keeps it: the
# other failure is recorded and no rollback starts. A reason that names
# this key, or COMPLETE with nothing failed and nothing modified, restores
# the backup body and starts one rollback ingestion on the same data
# source. That second ingestion is identified and is not polled here.
#
# A failure reason that does not contain that document pattern is not
# evidence. The shared filename chunk_p5_1.txt is not evidence. A FAILED
# job that does not name this key, a failed count with fewer named
# documents than failures, a missing status, or an AWS exception after the
# write stops the run. Those stops do not upload again, do not start
# another ingestion and do not restore on their own. A job still running
# at the poll limit does not start a second job.
#
# Rollback by hand: upload chunk_p5_1_before.bin through
# S3DocumentsService#upload_text at the same key, then start_ingestion_job
# on PJ0N58DMHG. Do not upload the sidecar backup.

abort("Set RAG_PAGE5_BOTONERA_BRANCH_CONFIRM=1 to run (mutates the production KB)") unless ENV["RAG_PAGE5_BOTONERA_BRANCH_CONFIRM"] == "1"

require "aws-sdk-bedrockagent"
require "fileutils"

require Rails.root.join("app/services/elemont_mh_page5_botonera_branch_patch")
require Rails.root.join("app/services/elemont_mh_page5_botonera_branch_repair")

repair_class = ElemontMhPage5BotoneraBranchRepair
ENV["AWS_REGION"] = repair_class::REGION
ENV["KNOWLEDGE_BASE_S3_BUCKET"] = repair_class::BUCKET

backup_dir = Rails.root.join("tmp/elemont_page5_botonera_branch", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
s3 = S3DocumentsService.new(bucket_name: repair_class::BUCKET)
agent = Aws::BedrockAgent::Client.new(region: repair_class::REGION)

repair = repair_class.new(
  s3: s3,
  agent: agent,
  bucket: repair_class::BUCKET,
  knowledge_base_id: repair_class::KNOWLEDGE_BASE_ID,
  data_source_id: repair_class::DATA_SOURCE_ID,
  region: repair_class::REGION,
  backup_dir: backup_dir,
  confirm: ENV["RAG_PAGE5_BOTONERA_BRANCH_CONFIRM"]
)

begin
  patched = repair.call
rescue ElemontMhPage5BotoneraBranchRepair::Stop => e
  abort(e.message)
end

puts "uploaded #{repair_class::KEY}"
puts "patched_sha256=#{ElemontMhPage5BotoneraBranchPatch.digest(patched)}"
puts "backup=#{backup_dir}"
puts "ingestions=#{repair.ingestions.inspect}"
repair.foreign_failures.each { |reason| puts "foreign_failure=#{reason}" }
