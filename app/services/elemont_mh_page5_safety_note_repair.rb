# frozen_string_literal: true

require "fileutils"

# One-object repair for ElemontMhPage5SafetyNotePatch::KEY.
#
# KbSyncService#find_data_source_id uses the first listed data source when
# the requested id is absent. This repair lists the data sources and stops
# instead. It calls start_ingestion_job on the exact id.
#
# The 2026-09-28 bornera script ran later jobs in process. That runs every
# perform_later of the process. This repair does not change the adapter and
# does not enqueue.
#
# The SHA of a captured body is not a precondition. The live bytes are
# backed up first, and the write proceeds only when the approved spans are
# present once and the complement is unchanged. The sidecar is read before
# and after the text upload and is never written.
#
# After the corrected body exists, its SHA is appended to the manifest.
# Each ingestion job id is appended, with role initial or rollback, before
# the next agent call. An AWS exception after the write records the last
# confirmed stage, the backup path and the job id when one was received.
# An uncertain start or status does not upload again, does not start
# another ingestion and does not restore on its own.
class ElemontMhPage5SafetyNoteRepair
  class Stop < StandardError; end

  POLL_LIMIT = 90
  RUNNING = %w[STARTING IN_PROGRESS].freeze
  KNOWN_STATUSES = (RUNNING + %w[COMPLETE FAILED]).freeze

  def initialize(s3:, agent:, bucket:, knowledge_base_id:, data_source_id:, backup_dir:, confirm:, sleep_for: nil)
    @s3 = s3
    @agent = agent
    @bucket = bucket
    @knowledge_base_id = knowledge_base_id
    @data_source_id = data_source_id
    @backup_dir = Pathname(backup_dir)
    @confirm = confirm
    @sleep_for = sleep_for || ->(seconds) { sleep(seconds) }
    @ingestions = []
    @stage = nil
    @last_job_id = nil
  end

  attr_reader :ingestions

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

  def ensure_authorized!
    return if @confirm == "1"

    raise Stop, "RAG_PAGE5_SAFETY_NOTE_CONFIRM=1 is required"
  end

  def ensure_target!
    patch = ElemontMhPage5SafetyNotePatch
    unless @bucket == patch::BUCKET && @s3.bucket_name == patch::BUCKET
      raise Stop, "bucket must be #{patch::BUCKET}"
    end
    raise Stop, "knowledge base must be #{patch::KNOWLEDGE_BASE_ID}" unless @knowledge_base_id == patch::KNOWLEDGE_BASE_ID
    raise Stop, "data source must be #{patch::DATA_SOURCE_ID}" unless @data_source_id == patch::DATA_SOURCE_ID
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
    live = @s3.download(ElemontMhPage5SafetyNotePatch::KEY)
    sidecar = @s3.download(ElemontMhPage5SafetyNotePatch::SIDECAR_KEY)
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
      key=#{ElemontMhPage5SafetyNotePatch::KEY}
      sidecar_key=#{ElemontMhPage5SafetyNotePatch::SIDECAR_KEY}
      live_sha256=#{ElemontMhPage5SafetyNotePatch.digest(live)}
      sidecar_sha256=#{ElemontMhPage5SafetyNotePatch.digest(sidecar)}
    MANIFEST
    @stage = "backup"
  end

  def record_patched!(patched)
    sha = ElemontMhPage5SafetyNotePatch.digest(patched)
    @stage = "patched"
    append_manifest!("patched_sha256=#{sha}\n")
  end

  def transform!(live)
    text = live.dup.force_encoding(Encoding::UTF_8)
    raise Stop, "live object is not valid UTF-8" unless text.valid_encoding?

    patched = ElemontMhPage5SafetyNotePatch.apply!(text)
    before = ElemontMhPage5SafetyNotePatch.unchanged_body(text)
    after = ElemontMhPage5SafetyNotePatch.unchanged_body(patched)
    raise Stop, "patch changed bytes outside the approved spans" unless before == after

    patched
  rescue ElemontMhPage5SafetyNotePatch::Error => e
    raise Stop, e.message
  end

  def publish!(live, patched, sidecar)
    key = ElemontMhPage5SafetyNotePatch::KEY
    sidecar_key = ElemontMhPage5SafetyNotePatch::SIDECAR_KEY
    uploaded = @s3.upload_text(key, patched)
    raise Stop, "text upload failed" unless uploaded == key

    confirm_stage!("text_uploaded")
    roundtrip = aws_call { @s3.download(key) }
    sidecar_after = aws_call { @s3.download(sidecar_key) }
    text_ok = !roundtrip.nil? && roundtrip.b == patched.b
    sidecar_ok = !sidecar_after.nil? && sidecar_after.b == sidecar.b
    return confirm_stage!("publish_checked") if text_ok && sidecar_ok

    restore_body!(live)
    raise Stop, "publish check failed; body restored from backup; sidecar was not written"
  end

  def sync!(data_source_id, live)
    ingestion = start_ingestion!(data_source_id, "initial")
    job = wait_for_job!(ingestion)
    return if job_ok?(job)

    if RUNNING.include?(job.status)
      raise Stop, "ingestion #{ingestion} still #{job.status}; backup kept at #{@backup_dir}; no second job started"
    end

    restore_body!(live)
    rollback = start_ingestion!(data_source_id, "rollback")
    raise Stop, "ingestion #{ingestion} ended #{job.status}; body restored; rollback job #{rollback}"
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

  def job_ok?(job)
    return false unless job.status == "COMPLETE"

    stats = job.statistics
    failed = stats&.number_of_documents_failed.to_i
    modified = stats&.number_of_modified_documents_indexed.to_i
    failed.zero? && modified.positive?
  end

  def restore_body!(live)
    uploaded = aws_call { @s3.upload_text(ElemontMhPage5SafetyNotePatch::KEY, live) }
    raise Stop, "rollback upload failed; backup remains in #{@backup_dir}" unless uploaded == ElemontMhPage5SafetyNotePatch::KEY

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
