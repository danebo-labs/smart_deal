# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"

# Publishes the prepared page-5 fragments of Wiring - 905.
# Replaces chunk_p5_1.txt, creates the two new fragments and their sidecars,
# and starts one ingestion job. A failed write, object check, or indexing of
# these keys restores the body captured before the write, deletes only keys
# that were absent, and starts one resync.
class Wiring905Page5Publication
  class Stop < StandardError
    attr_reader :stage

    def initialize(message, stage:)
      @stage = stage
      super(message)
    end
  end

  # S3 listing and single-key delete sit beside S3DocumentsService.
  # upload_binary stays on that service so a body write drops the neighbor index.
  class Remote
    delegate :object_record, to: :@store

    def initialize(store:, s3:, bucket:)
      @store = store
      @s3 = s3
      @bucket = bucket
    end

    def list_object_summaries!(prefix:)
      raise ArgumentError, "prefix required" if prefix.blank?

      rows = []
      token = nil
      20.times do
        params = { bucket: @bucket, prefix: prefix }
        params[:continuation_token] = token if token.present?
        response = @s3.list_objects_v2(**params)
        Array(response.contents).each do |object|
          rows << {
            "key" => object.key.to_s,
            "etag" => object.etag.to_s,
            "size" => object.size.to_i,
            "last_modified" => format_time(object.last_modified)
          }
        end
        break unless response.is_truncated

        token = response.next_continuation_token.to_s
        raise ArgumentError, "listing #{prefix} truncated without a token" if token.blank?
      end
      rows
    end

    def upload_binary(key, body, content_type)
      uploaded = @store.upload_binary(key, body, content_type)
      raise Stop.new("upload failed for #{key}", stage: :write) if uploaded != key

      key
    end

    # Raw DeleteObject bypasses S3DocumentsService. The caller drops the
    # neighbor index after a successful delete (ciclo 5 H1/H2).
    def delete_object!(key)
      @s3.delete_object(bucket: @bucket, key: key)
      key
    end

    private

    def format_time(value)
      return value.utc.iso8601(6) if value.respond_to?(:utc)

      value.to_s
    end
  end

  BUCKET = "multimodal-source-destination"
  PREFIX = "bulk_chunks/3/5b1859a0bfe1c5b11e58214555f8c2fe93e6/"
  VF5_MARKER = "be7a39a3490c92c8381cb883402760cb07d1"
  KNOWLEDGE_BASE_ID = "Y7RZWMFJSR"
  DATA_SOURCE_ID = "PJ0N58DMHG"
  DOCUMENT_ID = "5b1859a0bfe1c5b11e58214555f8c2fe93e6"
  SOURCE_SHA256 = Wiring905Page5ChunkSplit::SOURCE_SHA256
  SIDECAR_SHA256 = "7717b593b7da334a18b5480453353fe42bb3aba02f95ac01161906dfaa935eb2"
  FRAGMENT_SHA256 = {
    "chunk_p5_1.txt" => "3f432d6b11ca696181d99a5adc277b751e27f8d997b924e6f92fd424909c702f",
    "chunk_p5_2.txt" => "a852b9fd17355c4a5198579755fdcca85c4a4f591ae11079c1caa5c262049ab6",
    "chunk_p5_3.txt" => "d7aeaabf03a7bc576652b85ad17513a74ccd9e37fbee7ffcaeab755dd7daa47f"
  }.freeze
  FRAGMENT_BYTES = {
    "chunk_p5_1.txt" => 9502,
    "chunk_p5_2.txt" => 8971,
    "chunk_p5_3.txt" => 6452
  }.freeze
  SHARED_SIDECAR_KEYS = %w[
    account_id document_id original_source_uri original_filename canonical_name
    doc_sha256 ingestion_path ingestion_contract_version prompt_fingerprint_sha256
    aliases page_number
  ].freeze
  FRAGMENT_IDENTITY_KEYS = %w[
    chunk_id chunk_key chunk_ordinal ordinal source_key
    x-amz-bedrock-kb-source-uri x-amz-bedrock-kb-data-source-id
  ].freeze
  CREATED_NAMES = %w[
    chunk_p5_2.txt
    chunk_p5_2.txt.metadata.json
    chunk_p5_3.txt
    chunk_p5_3.txt.metadata.json
  ].freeze
  REQUIRED_TEXT = [
    "[DOCUMENT: Wiring - 905.pdf]",
    "[SOURCE_URI: s3://multimodal-source-destination/bulk_uploads/3/2026-08-24/Wiring - 905.pdf]",
    "S7 — DIAGRAM / SPECIFICATION PAGE 2/3",
    "Issue F: Pos. 101, 176, 732:1 added"
  ].freeze
  RUNNING = %w[STARTING IN_PROGRESS STOPPING].freeze
  RESTORE_STAGES = %i[write verify sync].freeze
  POLL_SECONDS = 15

  def self.call
    Vf5F4Publication.use_operator_profile!
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    evidence = Rails.root.join("tmp/field_companion/wiring_905_page5_publish/#{stamp}")
    options = Vf5F4Publication.operator_client_options.merge(max_attempts: 1)
    store = S3DocumentsService.new(bucket_name: BUCKET, client_options: options)
    new(
      remote: Remote.new(store: store, s3: Aws::S3::Client.new(options), bucket: BUCKET),
      agent: Aws::BedrockAgent::Client.new(options),
      kb_sync: KbSyncService.new(kb_id: KNOWLEDGE_BASE_ID, data_source_id: DATA_SOURCE_ID, client_options: options),
      source_body: fixture("chunk_p5_1.txt"),
      source_sidecar: fixture("chunk_p5_1.txt.metadata.json"),
      backup_dir: evidence.join("restore"),
      evidence_dir: evidence
    ).call
  end

  def self.fixture(name)
    Rails.root.join("test/fixtures/files/wiring_905", name).binread
  end

  def self.resume!(evidence_dir:)
    Vf5F4Publication.use_operator_profile!
    evidence = Pathname(evidence_dir)
    options = Vf5F4Publication.operator_client_options.merge(max_attempts: 1)
    store = S3DocumentsService.new(bucket_name: BUCKET, client_options: options)
    new(
      remote: Remote.new(store: store, s3: Aws::S3::Client.new(options), bucket: BUCKET),
      agent: Aws::BedrockAgent::Client.new(options),
      kb_sync: KbSyncService.new(kb_id: KNOWLEDGE_BASE_ID, data_source_id: DATA_SOURCE_ID, client_options: options),
      source_body: fixture("chunk_p5_1.txt"),
      source_sidecar: fixture("chunk_p5_1.txt.metadata.json"),
      backup_dir: evidence.join("restore"),
      evidence_dir: evidence
    ).resume!
  end

  def initialize(remote:, agent:, kb_sync:, source_body:, source_sidecar:, backup_dir:, evidence_dir:, sleep_for: nil, poll_limit: 80)
    @remote = remote
    @agent = agent
    @kb_sync = kb_sync
    @source_body = source_body.to_s.b
    @source_sidecar = source_sidecar.to_s.b
    @backup_dir = Pathname(backup_dir)
    @evidence_dir = Pathname(evidence_dir)
    @sleep_for = sleep_for || ->(seconds) { sleep(seconds) }
    @poll_limit = poll_limit
    @sync_labels = []
    @restore_started = false
    @uploaded = []
    @phase = :read
    @report = {}
  end

  attr_reader :report

  def resume!
    @report = JSON.parse(File.read(@evidence_dir.join("report.json")))
    @report["previous_stop"] = @report["stopped"]
    @report["stopped"] = nil
    @report["resume"] = "sync_only"
    load_candidate!
    assert_remote_config!
    load_backup_from_disk!
    confirm_publication!
    @phase = :sync
    sync_published!
    @report
  rescue Stop => error
    handle_stop(error)
    @report
  rescue StandardError => error
    stage = RESTORE_STAGES.include?(@phase) ? @phase : :read
    handle_stop(Stop.new("#{error.class}: #{error.message}", stage: stage))
    @report
  ensure
    persist_report!
  end

  def call
    FileUtils.mkdir_p(@evidence_dir)
    @report = base_report
    persist_report!
    load_candidate!
    assert_remote_config!
    wait_until_idle!(stage: :read)
    backup_remote!
    @phase = :write
    publish!
    @phase = :verify
    verify_published!
    @phase = :cache
    invalidate_local_caches!
    @phase = :sync
    sync_published!
    @report["stopped"] = nil
    @report
  rescue Stop => error
    handle_stop(error)
    @report
  rescue StandardError => error
    stage = RESTORE_STAGES.include?(@phase) ? @phase : :read
    handle_stop(Stop.new("#{error.class}: #{error.message}", stage: stage))
    @report
  ensure
    persist_report!
  end

  private

  def base_report
    {
      "region" => Vf5F4Publication::REGION,
      "bucket" => BUCKET,
      "prefix" => PREFIX,
      "knowledge_base_id" => KNOWLEDGE_BASE_ID,
      "data_source_id" => DATA_SOURCE_ID,
      "evidence_dir" => @evidence_dir.to_s,
      "aws_caller" => ENV["VF5_F4_CALLER_ARN"].presence,
      "vf5_prefix" => "bulk_chunks/1/#{VF5_MARKER}/",
      "vf5_written" => false
    }
  end

  def load_candidate!
    parts = Wiring905Page5ChunkSplit.call(body: @source_body, sidecar: @source_sidecar)
    assert_fragments!(parts)
    inspect_sidecar!(@source_sidecar)
  rescue Wiring905Page5ChunkSplit::Error => error
    raise Stop.new(error.message, stage: :read)
  end

  def assert_fragments!(parts)
    names = parts.pluck("filename")
    raise Stop.new("fragments #{names.join(', ')}", stage: :read) unless names == FRAGMENT_SHA256.keys

    parts.each do |part|
      name = part["filename"]
      body = part["body"]
      digest = sha(body)
      raise Stop.new("#{name} sha #{digest}", stage: :read) unless digest == FRAGMENT_SHA256.fetch(name)
      raise Stop.new("#{name} has #{body.b.bytesize} bytes", stage: :read) unless body.b.bytesize == FRAGMENT_BYTES.fetch(name)
      raise Stop.new("#{name} sidecar changed", stage: :read) unless sha(part["sidecar"]) == SIDECAR_SHA256

      REQUIRED_TEXT.each do |text|
        raise Stop.new("#{name} is missing required text", stage: :read) unless body.include?(text)
      end
    end
    keys = parts.flat_map { |part| position_keys(part["body"]) }
    raise Stop.new("positions #{keys.size}/#{keys.uniq.size}", stage: :read) unless keys.size == 56 && keys.uniq.size == 56
    raise Stop.new("revision record is not on the first fragment", stage: :read) unless revision_records(parts[0]["body"]) == 1
    raise Stop.new("revision record was copied", stage: :read) unless parts.drop(1).all? { |part| revision_records(part["body"]).zero? }

    @parts = parts.index_by { |part| part["filename"] }
    @report["fragments"] = parts.map { |part| fragment_report(part) }
    @report["titan_token_estimates_are_not_measurements"] = true
  end

  def fragment_report(part)
    part.except("body", "sidecar").merge(
      "sha256" => FRAGMENT_SHA256.fetch(part["filename"]),
      "sidecar_sha256" => SIDECAR_SHA256
    )
  end

  def revision_records(body)
    body.scan("RECORD_TYPE: DOCUMENTATION_REQUIREMENT").size
  end

  def position_keys(body)
    body.each_line.filter_map do |line|
      next unless line.start_with?("| ")
      next if line.include?("Pos. No.") || line.include?("|---|")

      line.split("|").map(&:strip).reject(&:empty?).first
    end
  end

  def inspect_sidecar!(bytes)
    parsed = JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8))
    raise Stop.new("sidecar schema is #{parsed.keys.join(',')}", stage: :read) unless parsed.keys == [ "metadataAttributes" ]

    attributes = parsed.fetch("metadataAttributes")
    keys = attributes.keys
    unexpected = (keys & FRAGMENT_IDENTITY_KEYS) + (keys - SHARED_SIDECAR_KEYS)
    if unexpected.any?
      raise Stop.new("sidecar fields need a per-fragment decision: #{unexpected.join(', ')}", stage: :read)
    end
    raise Stop.new("page_number is #{attributes['page_number']}", stage: :read) unless attributes["page_number"] == 5
    raise Stop.new("document_id is #{attributes['document_id']}", stage: :read) unless attributes["document_id"] == DOCUMENT_ID
    raise Stop.new("contract is #{attributes['ingestion_contract_version']}", stage: :read) unless attributes["ingestion_contract_version"] == "field_records_v8"
    raise Stop.new("sidecar sha #{sha(bytes)}", stage: :read) unless sha(bytes) == SIDECAR_SHA256

    @report["sidecar_review"] = {
      "decision" => "shared",
      "reason" => "Los metadatos identifican el documento y la página 5. La clave de S3 identifica el fragmento. No hay un campo de fragmento que haya que variar.",
      "keys" => keys.sort,
      "sha256" => SIDECAR_SHA256
    }
  end

  def assert_remote_config!
    resolved = @kb_sync.resolved_data_source_id
    raise Stop.new("data source resolved to #{resolved}", stage: :read) unless resolved == DATA_SOURCE_ID

    data_source = @agent.get_data_source(knowledge_base_id: KNOWLEDGE_BASE_ID, data_source_id: DATA_SOURCE_ID).data_source
    s3 = data_source.data_source_configuration.s3_configuration
    prefixes = Array(s3.inclusion_prefixes).map(&:to_s)
    strategy = data_source.vector_ingestion_configuration&.chunking_configuration&.chunking_strategy.to_s
    model = @agent.get_knowledge_base(knowledge_base_id: KNOWLEDGE_BASE_ID)
      .knowledge_base.knowledge_base_configuration.vector_knowledge_base_configuration.embedding_model_arn.to_s
    @report["data_source"] = {
      "id" => DATA_SOURCE_ID,
      "bucket_arn" => s3.bucket_arn.to_s,
      "inclusion_prefixes" => prefixes,
      "chunking_strategy" => strategy
    }
    @report["embedding_model_arn"] = model
    raise Stop.new("bucket is #{s3.bucket_arn}", stage: :read) unless s3.bucket_arn.to_s.include?(BUCKET)
    raise Stop.new("prefixes #{prefixes.join(', ')} do not cover #{PREFIX}", stage: :read) unless prefix_covered?(prefixes)
    raise Stop.new("chunking strategy is #{strategy}", stage: :read) unless strategy == "NONE"
    raise Stop.new("embedding model is #{model}", stage: :read) unless model.include?("amazon.titan-embed-text-v2:0")
  end

  def prefix_covered?(prefixes)
    return true if prefixes.empty?

    directory = PREFIX.delete_suffix("/")
    prefixes.any? do |item|
      cleaned = item.delete_suffix("/")
      cleaned.blank? || directory.start_with?(cleaned) || cleaned.start_with?(directory)
    end
  end

  def backup_remote!
    raise Stop.new("refusing prefix #{PREFIX}", stage: :read) if PREFIX.include?(VF5_MARKER)

    @before = index_summaries(list_prefix!)
    body = read_required!(object_key("chunk_p5_1.txt"))
    sidecar = read_required!(object_key("chunk_p5_1.txt.metadata.json"))
    body_sha = sha(body[:body])
    sidecar_sha = sha(sidecar[:body])
    raise Stop.new("remote body is #{body_sha}", stage: :read) unless body_sha == SOURCE_SHA256
    raise Stop.new("remote sidecar is #{sidecar_sha}", stage: :read) unless sidecar_sha == SIDECAR_SHA256

    @text_type = plain!(body, object_key("chunk_p5_1.txt"))
    @sidecar_type = plain!(sidecar, object_key("chunk_p5_1.txt.metadata.json"))
    @backup = [
      backup_record(body, body_sha),
      backup_record(sidecar, sidecar_sha)
    ]
    classify_new_keys!
    write_backup!
    @report["backup"] = {
      "manifest" => @backup_dir.join("manifest.json").to_s,
      "objects" => @backup.map { |record| public_record(record) },
      "absent" => @absent,
      "already_matched" => @already_matched,
      "readable" => true,
      "matches_remote" => true
    }
  end

  def classify_new_keys!
    @absent = []
    @already_matched = []
    CREATED_NAMES.each do |name|
      key = object_key(name)
      found = @remote.object_record(key)
      listed = @before.key?(key)
      raise Stop.new("#{key} is listed but unreadable", stage: :read) if listed && found.nil?
      raise Stop.new("#{key} is readable but not listed", stage: :read) if found && !listed
      if found.nil?
        @absent << key
        next
      end

      expected = bytes_for(name)
      actual = sha(found[:body])
      raise Stop.new("#{key} exists as #{actual}; the repair expects #{sha(expected)}", stage: :read) unless actual == sha(expected)

      plain!(found, key)
      @already_matched << key
    end
  end

  def write_backup!
    FileUtils.mkdir_p(@backup_dir)
    rows = @backup.map { |record| write_backup_object(record) }
    manifest = {
      "captured_at" => Time.now.utc.iso8601,
      "bucket" => BUCKET,
      "prefix" => PREFIX,
      "objects" => rows,
      "absent" => @absent
    }
    File.write(@backup_dir.join("manifest.json"), JSON.pretty_generate(manifest))
    parsed = JSON.parse(File.read(@backup_dir.join("manifest.json")))
    raise Stop.new("manifest is unreadable", stage: :read) unless parsed.fetch("objects").pluck("sha256") == @backup.pluck(:sha256)
  end

  def write_backup_object(record)
    path = @backup_dir.join("objects", record[:key])
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, record[:body])
    stored = File.binread(path)
    raise Stop.new("backup unreadable #{record[:key]}", stage: :read) unless sha(stored) == record[:sha256]

    fresh = read_required!(record[:key])
    raise Stop.new("backup drifted from remote #{record[:key]}", stage: :read) unless sha(fresh[:body]) == record[:sha256]
    raise Stop.new("backup content type drifted #{record[:key]}", stage: :read) unless fresh[:content_type].to_s == record[:content_type].to_s

    public_record(record)
  end

  def backup_record(record, digest)
    {
      key: record[:key],
      body: record[:body],
      content_type: record[:content_type].to_s,
      content_encoding: record[:content_encoding],
      metadata: record.fetch(:metadata, {}).to_h.transform_keys(&:to_s),
      sha256: digest,
      bytes: record[:body].to_s.b.bytesize
    }
  end

  def public_record(record)
    record.except(:body).transform_keys(&:to_s)
  end

  def publish!
    plan.each do |item|
      next if @already_matched.include?(item[:key])

      @remote.upload_binary(item[:key], item[:body], item[:content_type])
      @uploaded << item[:key]
    end
    raise Stop.new("write touched the VF5 prefix", stage: :write) if @uploaded.any? { |key| key.include?(VF5_MARKER) }

    @report["uploaded"] = @uploaded
    @report["vf5_written"] = false
  end

  def plan
    body = {
      key: object_key("chunk_p5_1.txt"),
      body: @parts.fetch("chunk_p5_1.txt").fetch("body"),
      content_type: @text_type
    }
    created = CREATED_NAMES.map do |name|
      {
        key: object_key(name),
        body: bytes_for(name),
        content_type: name.end_with?(".metadata.json") ? @sidecar_type : @text_type
      }
    end
    [ body ] + created
  end

  def bytes_for(name)
    return @source_sidecar if name.end_with?(".metadata.json")

    @parts.fetch(name).fetch("body")
  end

  def verify_published!
    FRAGMENT_SHA256.each do |name, digest|
      remote = read_required!(object_key(name), stage: :verify)
      raise Stop.new("#{name} published sha #{sha(remote[:body])}", stage: :verify) unless sha(remote[:body]) == digest
      raise Stop.new("#{name} content type #{remote[:content_type]}", stage: :verify) if @uploaded.include?(object_key(name)) && remote[:content_type].to_s != @text_type
    end
    sidecar_names.each do |name|
      key = object_key(name)
      remote = read_required!(key, stage: :verify)
      raise Stop.new("#{name} sidecar sha #{sha(remote[:body])}", stage: :verify) unless sha(remote[:body]) == SIDECAR_SHA256
      next unless @uploaded.include?(key)

      raise Stop.new("#{name} content type #{remote[:content_type]}", stage: :verify) unless remote[:content_type].to_s == @sidecar_type
    end
    after = index_summaries(list_prefix!)
    assert_inventory!(after)
    @report["published_sha256"] = published_hashes
    @report["prefix_count_before"] = @before.size
    @report["prefix_count_after"] = after.size
    @report["unchanged_key_count"] = (@before.keys - @uploaded).size
  end

  def sidecar_names
    [ "chunk_p5_1.txt.metadata.json" ] + CREATED_NAMES.select { |name| name.end_with?(".metadata.json") }
  end

  def published_hashes
    (FRAGMENT_SHA256.keys + sidecar_names).to_h do |name|
      digest = name.end_with?(".metadata.json") ? SIDECAR_SHA256 : FRAGMENT_SHA256.fetch(name)
      [ object_key(name), digest ]
    end
  end

  def assert_inventory!(after)
    disappeared = @before.keys - after.keys
    raise Stop.new("keys disappeared: #{disappeared.join(', ')}", stage: :verify) if disappeared.any?

    unexpected = (after.keys - @before.keys) - @uploaded
    raise Stop.new("unexpected keys: #{unexpected.join(', ')}", stage: :verify) if unexpected.any?

    changed = @before.keys.select { |key| @uploaded.exclude?(key) && @before[key] != after[key] }
    raise Stop.new("other keys changed: #{changed.join(', ')}", stage: :verify) if changed.any?

    @report["inventory_before"] = @before
    @report["inventory_after"] = after
  end

  def sync_published!
    snapshot = start_and_wait!("sync")
    decide!(snapshot)
    @report["verdict"] = "accepted"
  end

  def decide!(snapshot)
    reasons = snapshot["failure_reasons"]
    ours = reasons.select { |reason| ours?(reason) }
    @report["foreign_failures"] = reasons.reject { |reason| ours?(reason) }
    token = reasons.any? { |reason| reason.include?("9048") && reason.include?(object_key("chunk_p5_1.txt")) }
    return if snapshot["status"] == "COMPLETE" && ours.empty? && !token && explained?(snapshot, reasons)

    if ours.any? || token
      raise Stop.new("ingestion rejected this page: #{ours.join(' | ')}", stage: :sync)
    end

    raise Stop.new("ingestion finished #{snapshot['status']}", stage: :sync_result)
  end

  def explained?(snapshot, reasons)
    failed = snapshot.dig("statistics", "failed").to_i
    return true if failed.zero? || reasons.any?

    raise Stop.new("failed count #{failed} without reasons", stage: :sync_result)
  end

  def ours?(reason)
    reason.include?(PREFIX) && (
      reason.include?("chunk_p5_1.txt") || reason.include?("chunk_p5_2.txt") || reason.include?("chunk_p5_3.txt")
    )
  end

  def start_and_wait!(label)
    raise Stop.new("ingestion start already recorded", stage: :sync_running) if @sync_labels.include?(label)
    raise Stop.new("too many ingestion starts", stage: :sync_running) if @sync_labels.size >= 2

    wait_until_idle!(stage: :sync_running)
    @sync_labels << label
    snapshot = wait_for_job!(start_job!)
    @report["#{label}_result"] = snapshot
    snapshot
  end

  def start_job!
    before = running_job_ids
    response = Bedrock::AuroraColdStartRetry.with_retry(
      error_classes: [ Aws::BedrockAgent::Errors::ServiceError ],
      on_retry: lambda { |attempt, delay|
        (@report["aurora_retries"] ||= []) << { "attempt" => attempt, "delay_seconds" => delay }
      }
    ) do
      adopted = adopt_running!(before)
      next adopted if adopted

      @agent.start_ingestion_job(knowledge_base_id: KNOWLEDGE_BASE_ID, data_source_id: DATA_SOURCE_ID)
    end
    return finish_adopted(response) if response.is_a?(String)

    job = response.ingestion_job
    assert_job_target!(job)
    job_id = job.ingestion_job_id.to_s
    raise Stop.new("ingestion job id missing", stage: :sync_start) if job_id.blank?

    (@report["start_requests"] ||= []) << {
      "knowledge_base_id" => KNOWLEDGE_BASE_ID,
      "data_source_id" => DATA_SOURCE_ID,
      "job_id" => job_id
    }
    job_id
  rescue Stop
    raise
  rescue StandardError => error
    appeared = running_job_ids - before
    raise Stop.new("ingestion did not start: #{error.class}: #{error.message}", stage: :sync_start) unless appeared.size == 1

    finish_adopted(appeared.first)
  end

  def adopt_running!(before)
    appeared = running_job_ids - before
    return nil if appeared.empty?
    raise Stop.new("multiple ingestion jobs appeared: #{appeared.join(', ')}", stage: :sync_running) if appeared.size > 1

    appeared.first
  end

  def finish_adopted(job_id)
    @report["start_adopted"] = job_id
    job_id
  end

  def load_backup_from_disk!
    parsed = JSON.parse(File.read(@backup_dir.join("manifest.json")))
    @absent = parsed.fetch("absent")
    @backup = parsed.fetch("objects").map { |row| disk_backup(row) }
    original = @backup.find { |record| record[:key] == object_key("chunk_p5_1.txt") }
    raise Stop.new("backup is missing the original body", stage: :read) unless original && original[:sha256] == SOURCE_SHA256
  end

  def disk_backup(row)
    body = File.binread(@backup_dir.join("objects", row.fetch("key")))
    digest = row.fetch("sha256")
    raise Stop.new("backup file drifted #{row['key']}", stage: :read) unless sha(body) == digest

    {
      key: row.fetch("key"),
      body: body,
      content_type: row.fetch("content_type").to_s,
      content_encoding: row["content_encoding"],
      metadata: row.fetch("metadata", {}).to_h.transform_keys(&:to_s),
      sha256: digest,
      bytes: body.bytesize
    }
  end

  def confirm_publication!
    FRAGMENT_SHA256.each do |name, digest|
      remote = read_required!(object_key(name), stage: :verify)
      raise Stop.new("#{name} is #{sha(remote[:body])}", stage: :verify) unless sha(remote[:body]) == digest
    end
    sidecar_names.each do |name|
      remote = read_required!(object_key(name), stage: :verify)
      raise Stop.new("#{name} sidecar is #{sha(remote[:body])}", stage: :verify) unless sha(remote[:body]) == SIDECAR_SHA256
    end
    count = list_prefix!.size
    expected = @report["prefix_count_after"]
    raise Stop.new("prefix count is #{count}, expected #{expected}", stage: :read) unless count == expected

    @report["resume_verified_sha256"] = published_hashes
  end

  def assert_job_target!(job)
    kb = job.knowledge_base_id.to_s
    source = job.data_source_id.to_s
    return if (kb.blank? || kb == KNOWLEDGE_BASE_ID) && (source.blank? || source == DATA_SOURCE_ID)

    raise Stop.new("job started on #{kb}/#{source}", stage: :sync_running)
  end

  def wait_for_job!(job_id)
    last = nil
    @poll_limit.times do
      last = job_snapshot(job_id)
      (@report["job_polls"] ||= []) << last
      persist_report!
      return last if %w[COMPLETE FAILED STOPPED].include?(last["status"])

      @sleep_for.call(POLL_SECONDS)
    end
    raise Stop.new("ingestion #{job_id} still #{last&.dig('status')}", stage: :sync_running)
  end

  def job_snapshot(job_id)
    job = @agent.get_ingestion_job(
      knowledge_base_id: KNOWLEDGE_BASE_ID,
      data_source_id: DATA_SOURCE_ID,
      ingestion_job_id: job_id
    ).ingestion_job
    stats = job.statistics
    {
      "job_id" => job.ingestion_job_id.to_s,
      "status" => job.status.to_s,
      "failure_reasons" => Array(job.failure_reasons).map(&:to_s),
      "statistics" => {
        "scanned" => stat(stats, :number_of_documents_scanned),
        "metadata_scanned" => stat(stats, :number_of_metadata_documents_scanned),
        "new_indexed" => stat(stats, :number_of_new_documents_indexed),
        "modified_indexed" => stat(stats, :number_of_modified_documents_indexed),
        "metadata_modified" => stat(stats, :number_of_metadata_documents_modified),
        "deleted" => stat(stats, :number_of_documents_deleted),
        "failed" => stat(stats, :number_of_documents_failed)
      }
    }
  end

  def stat(stats, method)
    return nil if stats.nil? || !stats.respond_to?(method)

    value = stats.public_send(method)
    value.nil? ? nil : value.to_i
  end

  def wait_until_idle!(stage:)
    @poll_limit.times do |attempt|
      ids = running_job_ids
      (@report["idle_checks"] ||= []) << { "attempt" => attempt, "running" => ids, "stage" => stage.to_s }
      persist_report!
      return if ids.empty?

      @sleep_for.call(POLL_SECONDS)
    end
    raise Stop.new("ingestion still active: #{running_job_ids.join(', ')}", stage: stage)
  end

  def running_job_ids
    ids = []
    token = nil
    10.times do
      params = { knowledge_base_id: KNOWLEDGE_BASE_ID, data_source_id: DATA_SOURCE_ID }
      params[:next_token] = token if token.present?
      response = @agent.list_ingestion_jobs(**params)
      Array(response.ingestion_job_summaries).each do |job|
        ids << job.ingestion_job_id.to_s if RUNNING.include?(job.status.to_s)
      end
      token = response.respond_to?(:next_token) ? response.next_token.to_s : ""
      break if token.blank?
    end
    ids
  end

  def handle_stop(error)
    @report["stopped"] = { "stage" => error.stage.to_s, "message" => error.message }
    @report["verdict"] ||= "impediment"
    return unless should_restore?(error)

    restore_once!(error.message)
  rescue Stop => restore_error
    @report["restore_stopped"] = { "stage" => restore_error.stage.to_s, "message" => restore_error.message }
  rescue StandardError => restore_error
    @report["restore_stopped"] = { "stage" => "restore", "message" => "#{restore_error.class}: #{restore_error.message}" }
  end

  def should_restore?(error)
    !@restore_started && @backup && RESTORE_STAGES.include?(error.stage)
  end

  def restore_once!(reason)
    raise Stop.new("restore already attempted", stage: :restore) if @restore_started

    @restore_started = true
    @report["restore_reason"] = reason
    wait_until_idle!(stage: :restore)
    original = @backup.find { |record| record[:key] == object_key("chunk_p5_1.txt") }
    raise Stop.new("backup is missing the original body", stage: :restore) if original.nil?

    @remote.upload_binary(original[:key], original[:body], original[:content_type])
    @absent.each do |key|
      raise Stop.new("refusing to delete #{key}", stage: :restore) unless deletable?(key)

      @remote.delete_object!(key)
    end
    # Ciclo 5 H1/H2: DeleteObject bypasses S3DocumentsService, which is the
    # path that drops the neighbor index on upload_binary.
    invalidate_local_caches!
    verify_restored!(original)
    @report["verdict"] = "restored"
    @report["size_error_resolved"] = false
    @report["restored_state"] = "El cuerpo original volvió a S3. Ese cuerpo sigue superando el límite de Titan; la restauración recupera el estado anterior y no corrige ese error."
    snapshot = start_and_wait!("resync")
    @report["resync_known_size_error"] = snapshot["failure_reasons"].any? { |reason| reason.include?("9048") }
  end

  def deletable?(key)
    key.start_with?(PREFIX) && key.exclude?(VF5_MARKER) && CREATED_NAMES.any? { |name| key == object_key(name) }
  end

  def verify_restored!(original)
    remote = read_required!(original[:key], stage: :restore)
    raise Stop.new("restored body sha #{sha(remote[:body])}", stage: :restore) unless sha(remote[:body]) == original[:sha256]
    raise Stop.new("restored content type #{remote[:content_type]}", stage: :restore) unless remote[:content_type].to_s == original[:content_type].to_s

    metadata = remote.fetch(:metadata, {}).to_h.transform_keys(&:to_s)
    raise Stop.new("restored metadata differs", stage: :restore) unless metadata == original[:metadata]
    sidecar = read_required!(object_key("chunk_p5_1.txt.metadata.json"), stage: :restore)
    raise Stop.new("sidecar changed during restore", stage: :restore) unless sha(sidecar[:body]) == SIDECAR_SHA256

    listed = index_summaries(list_prefix!)
    @absent.each do |key|
      raise Stop.new("created key remains #{key}", stage: :restore) if listed.key?(key) || @remote.object_record(key)
    end
    @report["restored"] = true
  end

  def invalidate_local_caches!
    prefix = PREFIX.delete_suffix("/")
    neighbor = Rag::SectionNeighborExpander.index_cache_key(prefix)
    definition = Rag::CompanionDefinitionSource.cache_key(prefix)
    Rails.cache.write(neighbor, { "wiring905" => true })
    Rails.cache.write(definition, [ { "wiring905" => true } ])
    Rag::SectionNeighborExpander.invalidate!(prefix)
    Rag::CompanionDefinitionSource.invalidate!(prefix)
    @report["cache_invalidated"] = {
      "neighbor_absent" => Rails.cache.read(neighbor).nil?,
      "definitions_absent" => Rails.cache.read(definition).nil?,
      "store" => Rails.cache.class.name,
      "scope" => "this process"
    }
  end

  def list_prefix!
    raise Stop.new("refusing to list #{PREFIX}", stage: :read) unless PREFIX == "bulk_chunks/3/#{DOCUMENT_ID}/"

    @remote.list_object_summaries!(prefix: PREFIX)
  end

  def object_key(name)
    raise Stop.new("refusing #{name}", stage: :read) if name.blank? || name.include?("/") || name.include?("..")

    key = "#{PREFIX}#{name}"
    raise Stop.new("refusing #{key}", stage: :read) unless key.start_with?(PREFIX) && key.exclude?(VF5_MARKER)

    key
  end

  def read_required!(key, stage: :read)
    record = @remote.object_record(key)
    raise Stop.new("could not read #{key}", stage: stage) if record.nil? || record[:body].nil?

    record
  end

  def plain!(record, key)
    metadata = record.fetch(:metadata, {}).to_h.transform_keys(&:to_s)
    raise Stop.new("#{key} has object metadata", stage: :read) if metadata.any?
    raise Stop.new("#{key} has content encoding", stage: :read) if record[:content_encoding].present?

    type = record[:content_type].to_s
    raise Stop.new("#{key} has no content type", stage: :read) if type.blank?

    type
  end

  def index_summaries(rows)
    rows.to_h { |row| [ row.fetch("key"), row.except("key") ] }
  end

  def sha(bytes)
    Digest::SHA256.hexdigest(bytes.to_s.b)
  end

  def persist_report!
    return if @evidence_dir.blank?

    FileUtils.mkdir_p(@evidence_dir)
    File.write(@evidence_dir.join("report.json"), JSON.generate(@report))
  end
end
