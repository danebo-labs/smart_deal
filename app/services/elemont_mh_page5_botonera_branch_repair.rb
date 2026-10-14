# frozen_string_literal: true

require "fileutils"

# One-object repair for ElemontMhPage5BotoneraBranchPatch.
#
# Same destination and key as ElemontMhPage5SafetyNoteRepair, and the same
# protections where they still fit: confirm before any client work, list the
# data source and stop instead of falling back, back up the body and sidecar
# before the upload, write only the .txt, re-read both, record each stage and
# job id before the next agent call, and stop on an uncertain AWS result
# without uploading again or starting another ingestion.
#
# This class does not call that repair and does not read its confirm env.
# RAG_PAGE5_SAFETY_NOTE_CONFIRM does not authorize this one.
#
# The live core must be the safety-line body
# (BASE_SHA, with at most one trailing newline). The upload must be the
# approved candidate (CANDIDATE_SHA, same newline). A different base stops
# after the backup and before upload_text.
#
# A document failure rolls the body back only when a failure reason names
# this key, or when the job is COMPLETE with nothing failed and nothing
# modified. A COMPLETE job that modified a document and whose failure
# reasons name only other bulk_chunks documents keeps the new body and does
# not start a rollback ingestion. A failure that does not name a document
# key, a FAILED job that does not name this key, or any other uncertain
# outcome stops. It does not restore and it does not start another job.
#
# The script is the entry point. Preparing this class does not run it.
class ElemontMhPage5BotoneraBranchRepair
  class Stop < StandardError; end

  POLL_LIMIT = 90
  RUNNING = %w[STARTING IN_PROGRESS].freeze
  KNOWN_STATUSES = (RUNNING + %w[COMPLETE FAILED]).freeze
  DOCUMENT_KEY = %r{bulk_chunks/\d+/[0-9a-f]{16,}/chunk_p\d+_\d+\.txt}

  KEY = "bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p5_1.txt"
  SIDECAR_KEY = "#{KEY}.metadata.json"
  BUCKET = "multimodal-source-destination"
  KNOWLEDGE_BASE_ID = "Y7RZWMFJSR"
  DATA_SOURCE_ID = "PJ0N58DMHG"
  REGION = "us-east-1"
  CONFIRM_ENV = "RAG_PAGE5_BOTONERA_BRANCH_CONFIRM"
  BASE_SHA = "067ff45ffa86a6d055cedbec8f38ce63ae36c5ba15266d32a48da5ccea9c6831"
  CANDIDATE_SHA = "a13141fe7586c9013d698aa29f2b6809f112702e98f4da99d9a47c3ba01d7779"

  def initialize(s3:, agent:, bucket:, knowledge_base_id:, data_source_id:, region:, backup_dir:, confirm:, sleep_for: nil)
    @s3 = s3
    @agent = agent
    @bucket = bucket
    @knowledge_base_id = knowledge_base_id
    @data_source_id = data_source_id
    @region = region
    @backup_dir = Pathname(backup_dir)
    @confirm = confirm
    @sleep_for = sleep_for || ->(seconds) { sleep(seconds) }
    @ingestions = []
    @foreign_failures = []
    @stage = nil
    @last_job_id = nil
  end

  attr_reader :ingestions, :foreign_failures

  def call
    ensure_authorized!
    ensure_target!
    resolved = resolve_data_source!
    live, sidecar = download_pair!
    backup!(live, sidecar)
    patched = transform!(live)
    record_patched!(patched)
    publish!(live, patched, sidecar)
    sync!(resolved, live)
    patched
  end

  private

  def patch
    ElemontMhPage5BotoneraBranchPatch
  end

  def ensure_authorized!
    return if @confirm == "1"

    raise Stop, "#{CONFIRM_ENV}=1 is required"
  end

  def ensure_target!
    raise Stop, "bucket must be #{BUCKET}" unless @bucket == BUCKET && @s3.bucket_name == BUCKET
    raise Stop, "knowledge base must be #{KNOWLEDGE_BASE_ID}" unless @knowledge_base_id == KNOWLEDGE_BASE_ID
    raise Stop, "data source must be #{DATA_SOURCE_ID}" unless @data_source_id == DATA_SOURCE_ID
    raise Stop, "region must be #{REGION}" unless @region == REGION
  end

  def resolve_data_source!
    token = nil
    10.times do
      params = { knowledge_base_id: @knowledge_base_id }
      params[:next_token] = token if token
      response = @agent.list_data_sources(**params)
      summaries = Array(response.data_source_summaries)
      match = summaries.find { |summary| summary.data_source_id == @data_source_id }
      return match.data_source_id if match

      token = response.next_token
      return missing_data_source! if token.blank?
    end
    missing_data_source!
  end

  def missing_data_source!
    raise Stop, "data source #{@data_source_id} is not in #{@knowledge_base_id}"
  end

  def download_pair!
    live = @s3.download(KEY)
    sidecar = @s3.download(SIDECAR_KEY)
    raise Stop, "chunk download failed" if live.nil?
    raise Stop, "sidecar download failed" if sidecar.nil?

    [ live, sidecar ]
  end

  def backup!(live, sidecar)
    FileUtils.mkdir_p(@backup_dir)
    body_path = @backup_dir.join("chunk_p5_1_before.bin")
    sidecar_path = @backup_dir.join("chunk_p5_1.metadata.json.before")
    File.binwrite(body_path, live)
    File.binwrite(sidecar_path, sidecar)
    raise Stop, "backup body mismatch" unless File.binread(body_path).b == live.b
    raise Stop, "backup sidecar mismatch" unless File.binread(sidecar_path).b == sidecar.b

    File.write(@backup_dir.join("manifest.txt"), <<~MANIFEST)
      key=#{KEY}
      sidecar_key=#{SIDECAR_KEY}
      bucket=#{BUCKET}
      knowledge_base_id=#{KNOWLEDGE_BASE_ID}
      data_source_id=#{DATA_SOURCE_ID}
      region=#{REGION}
      live_sha256=#{patch.digest(live)}
      sidecar_sha256=#{patch.digest(sidecar)}
    MANIFEST
    @stage = "backup"
  end

  def record_patched!(patched)
    @stage = "patched"
    append_manifest!(<<~TEXT)
      expected_base_sha256=#{BASE_SHA}
      expected_candidate_sha256=#{CANDIDATE_SHA}
      patched_sha256=#{patch.digest(patched)}
    TEXT
  end

  def transform!(live)
    text = utf8!(live)
    raise Stop, "expected base #{BASE_SHA}" unless expected_base?(text)

    patched = patch.apply!(text)
    raise Stop, "transformation is not the approved candidate #{CANDIDATE_SHA}" unless exact_candidate?(text, patched)

    before = patch.unchanged_body(text)
    after = patch.unchanged_body(patched)
    raise Stop, "patch changed bytes outside the approved spans" unless before == after

    patched
  rescue patch::Error => e
    raise Stop, e.message
  end

  def utf8!(live)
    text = live.dup.force_encoding(Encoding::UTF_8)
    raise Stop, "live object is not valid UTF-8" unless text.valid_encoding?

    text
  end

  def expected_base?(text)
    return false if text.end_with?("\n\n")

    core = text.end_with?("\n") ? text.delete_suffix("\n") : text
    patch.digest(core) == BASE_SHA
  end

  def exact_candidate?(live, patched)
    return false if patched.end_with?("\n\n")
    return false unless live.end_with?("\n") == patched.end_with?("\n")

    core = patched.end_with?("\n") ? patched.delete_suffix("\n") : patched
    patch.digest(core) == CANDIDATE_SHA
  end

  def publish!(live, patched, sidecar)
    uploaded = aws_call { @s3.upload_text(KEY, patched) }
    halt_uncertain!("text upload failed") unless uploaded == KEY

    confirm_stage!("text_uploaded")
    roundtrip = aws_call { @s3.download(KEY) }
    sidecar_after = aws_call { @s3.download(SIDECAR_KEY) }
    text_ok = !roundtrip.nil? && roundtrip.b == patched.b
    sidecar_ok = !sidecar_after.nil? && sidecar_after.b == sidecar.b
    return confirm_stage!("publish_checked") if text_ok && sidecar_ok

    restore_body!(live)
    raise Stop, "publish check failed; body restored from backup; sidecar was not written"
  end

  def sync!(data_source_id, live)
    ingestion = start_ingestion!(data_source_id, "initial")
    job = wait_for_job!(ingestion)
    decide!(data_source_id, live, ingestion, job)
  end

  def decide!(data_source_id, live, ingestion, job)
    if RUNNING.include?(job.status)
      raise Stop, "ingestion #{ingestion} still #{job.status}; backup kept at #{@backup_dir}; no second job started"
    end

    kind = attribution(job)
    record_failure_evidence!(job, kind)
    case kind
    when "clean"
      nil
    when "foreign"
      accept_foreign!(job)
    when "target", "unmodified"
      rollback!(data_source_id, live, ingestion, job, kind)
    else
      stop_uncertain!(ingestion, job)
    end
  end

  def attribution(job)
    keys = failure_document_keys(job)
    return "target" if keys.include?(KEY)

    failed = integer_stat(job, :number_of_documents_failed)
    modified = integer_stat(job, :number_of_modified_documents_indexed)
    return "unattributed" if failed.nil? || modified.nil?
    return attribution_when_counted(job, keys, failed, modified) if job.status == "COMPLETE"

    "unattributed"
  end

  def attribution_when_counted(job, keys, failed, modified)
    return "clean" if failed.zero? && modified.positive?
    return "foreign" if foreign_only?(job, keys, failed, modified)
    return "unmodified" if modified.zero? && failed.zero?

    "unattributed"
  end

  def foreign_only?(job, keys, failed, modified)
    modified.positive? && failed.positive? && unnamed_reasons(job).zero? && keys.size >= failed
  end

  def failure_document_keys(job)
    failure_reasons(job).flat_map { |reason| document_keys(reason) }.uniq
  end

  def unnamed_reasons(job)
    failure_reasons(job).count { |reason| document_keys(reason).empty? }
  end

  def document_keys(reason)
    reason.to_s.downcase.scan(DOCUMENT_KEY).uniq
  end

  def failure_reasons(job)
    return [] unless job.respond_to?(:failure_reasons)

    Array(job.failure_reasons).map(&:to_s)
  end

  def integer_stat(job, name)
    stats = job.statistics
    return nil unless stats.respond_to?(name)

    value = stats.public_send(name)
    return nil if value.nil?

    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  def record_failure_evidence!(job, kind)
    lines = [
      "documents_failed=#{stat_text(job, :number_of_documents_failed)}",
      "documents_modified=#{stat_text(job, :number_of_modified_documents_indexed)}",
      *failure_reasons(job).map { |reason| "failure_reason=#{one_line(reason)}" },
      "failure_attribution=#{kind}"
    ]
    append_manifest!(lines.join("\n") + "\n")
  end

  def stat_text(job, name)
    value = integer_stat(job, name)
    value.nil? ? "missing" : value.to_s
  end

  def one_line(text)
    text.to_s.gsub(/\s+/, " ")
  end

  def accept_foreign!(job)
    @foreign_failures = failure_reasons(job)
    confirm_stage!("foreign_failures_accepted")
  end

  def rollback!(data_source_id, live, ingestion, job, kind)
    restore_body!(live)
    rollback_job = start_ingestion!(data_source_id, "rollback")
    raise Stop, rollback_message(ingestion, job, rollback_job, kind)
  end

  def rollback_message(ingestion, job, rollback_job, kind)
    cause = kind == "target" ? "target document failed" : "target document was not modified"
    "ingestion #{ingestion} ended #{job.status}; #{cause}; body restored; rollback job #{rollback_job}"
  end

  def stop_uncertain!(ingestion, job)
    confirm_stage!("outcome_uncertain")
    failed = stat_text(job, :number_of_documents_failed)
    modified = stat_text(job, :number_of_modified_documents_indexed)
    raise Stop, "ingestion #{ingestion} outcome uncertain status=#{job.status} failed=#{failed} " \
      "modified=#{modified}; no rollback; no second job; backup=#{@backup_dir}; job_id=#{ingestion}"
  end

  def start_ingestion!(data_source_id, role)
    response = aws_call do
      @agent.start_ingestion_job(
        knowledge_base_id: @knowledge_base_id,
        data_source_id: data_source_id
      )
    end
    job_id = response&.ingestion_job&.ingestion_job_id
    halt_uncertain!("ingestion start returned no job_id") if job_id.blank?

    @last_job_id = job_id
    @stage = role == "rollback" ? "rollback_started" : "ingestion_started"
    @ingestions << { job_id: job_id, data_source_id: data_source_id, role: role }
    append_manifest!("job_id=#{job_id} role=#{role}\n")
    job_id
  end

  def wait_for_job!(job_id)
    attempts = 0
    loop do
      job = observed_job!(job_id)
      return job unless RUNNING.include?(job.status)

      attempts += 1
      return job if attempts >= POLL_LIMIT

      @sleep_for.call(10)
    end
  end

  def observed_job!(job_id)
    response = aws_call do
      @agent.get_ingestion_job(
        knowledge_base_id: @knowledge_base_id,
        data_source_id: @data_source_id,
        ingestion_job_id: job_id
      )
    end
    job = response&.ingestion_job
    status = job&.status.to_s
    halt_uncertain!("ingestion status missing for #{job_id}") if status.empty?
    halt_uncertain!("ingestion status unrecognized: #{status}") unless KNOWN_STATUSES.include?(status)

    confirm_stage!("ingestion_observed job_id=#{job_id} status=#{status}")
    job
  end

  def restore_body!(live)
    uploaded = aws_call { @s3.upload_text(KEY, live) }
    raise Stop, "rollback upload failed; backup remains in #{@backup_dir}" unless uploaded == KEY

    confirm_stage!("body_restored")
  end

  def confirm_stage!(stage)
    @stage = stage
    append_manifest!("stage=#{stage}\n")
  end

  def aws_call
    yield
  rescue Stop
    raise
  rescue StandardError => error
    halt_uncertain!(error)
  end

  def halt_uncertain!(error)
    detail = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    lines = [
      "confirmed_stage=#{@stage}",
      "backup_dir=#{@backup_dir}",
      ("job_id=#{@last_job_id}" if @last_job_id),
      "aws_error=#{detail}"
    ]
    append_manifest!(lines.compact.join("\n") + "\n")
    reported_job = @last_job_id.nil? ? "not_received" : @last_job_id
    raise Stop, "aws error after write: #{detail}; confirmed_stage=#{@stage}; backup=#{@backup_dir}; job_id=#{reported_job}"
  end

  def append_manifest!(text)
    File.open(@backup_dir.join("manifest.txt"), "a") do |file|
      file.write(text)
      file.flush
      file.fsync
    end
  end
end
