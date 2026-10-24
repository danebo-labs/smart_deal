# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"

# Publishes the accepted VF5 candidate under its prefix, syncs the configured
# data source, and checks Retrieve plus catalog rehydration.
#
# A failed delete, upload, or sync stops the normal path. Writing or syncing
# can restore the verified backup once and start one resync. A retrieval miss
# does not restore the prefix.
class Vf5F4Publication
  include AwsClientInitializer

  class Stop < StandardError
    attr_reader :stage

    def initialize(message, stage:)
      @stage = stage
      super(message)
    end
  end

  BUCKET = "multimodal-source-destination"
  PREFIX = "bulk_chunks/1/be7a39a3490c92c8381cb883402760cb07d1/"
  KNOWLEDGE_BASE_ID = "Y7RZWMFJSR"
  DATA_SOURCE_ID = "PJ0N58DMHG"
  REGION = "us-east-1"
  PIN_URI = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
  TARGET_KEY = "#{PREFIX}chunk_p12_5.txt"
  TARGET_SHA = "aeab3d5afb150beaad789399355d2c500f746f41ee7183e2a58283122ebbca48"
  CANDIDATE_GIT_SHA = "cebd7de6ff95dbd110b6017afc4f76cb828718e2"
  EXCLUDED = %w[chunk_p7_4.txt chunk_p8_4.txt].freeze
  TEXT_TYPE = "text/plain; charset=utf-8"
  POLL_SECONDS = 30
  RUNNING = %w[STARTING IN_PROGRESS].freeze
  TERMINAL = %w[COMPLETE FAILED STOPPED].freeze
  # First turn of vf5-bound-20261020T1728Z, correlation query:0688864e-134f-4f9b-92d7-ead86845c6a6.
  # The capture marks the composition truncated because later components were dropped.
  # The symptom remains inside this text, so QueryComposer is not the allowed adjustment.
  RETRIEVAL_QUERY = "Prueba simulada. Estoy con un operador Fermator VF5+: en funcionamiento normal la puerta empieza a cerrar y vuelve a abrirse sola. El LED de fotocélula está encendido, no observo una obstrucción mecánica y no he revisado la sensibilidad de reapertura. SW4 está en OFF, modo esclavo. No hice mediciones ni reparaciones. Según el manual, ¿cómo me orientas y qué falta comprobar?"
  GROUP_PHRASES = [
    "La puerta se re-abre sola",
    "Comprobar la sensibilidad",
    "fotocélula",
    "obstrucción mecánica",
    "En caso que el problema persista",
    "Si la puerta no se abre o cierra completamente"
  ].freeze
  NEXT_SYMPTOM = "La puerta no alcanza la posición de apertura completa"
  SIDECAR_KEYS = %w[account_id document_id original_source_uri doc_sha256 ingestion_path ingestion_contract_version].freeze

  def self.call(**kwargs)
    return new(**kwargs).call if kwargs[:store]

    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    evidence = Rails.root.join("tmp/field_companion/vf5_correction/f4/#{stamp}")
    options = operator_client_options
    new(
      store: S3DocumentsService.new(bucket_name: BUCKET, client_options: options),
      agent: Aws::BedrockAgent::Client.new(options),
      runtime: Aws::BedrockAgentRuntime::Client.new(options),
      kb_sync: KbSyncService.new(kb_id: KNOWLEDGE_BASE_ID, data_source_id: DATA_SOURCE_ID, client_options: options),
      candidate_dir: Rails.root.join("tmp/field_companion/vf5_correction/f2f3_joint/f2/candidate_r2"),
      backup_dir: evidence.join("restore"),
      evidence_dir: evidence
    ).call
  end

  # The application user in .env can read this data source and cannot list its
  # ingestion jobs. The operator profile already used for this account can.
  # The credentials object is passed to the clients and is not written to the report.
  def self.use_operator_profile!(name = "default")
    resolved = Aws::SharedCredentials.new({ profile_name: name }).credentials
    raise ArgumentError, "AWS profile #{name} has no static credentials" unless resolved&.set?
    raise ArgumentError, "AWS profile #{name} is a temporary session" if resolved.session_token.to_s != ""

    identity = Aws::STS::Client.new(region: REGION, credentials: resolved).get_caller_identity
    unless identity.arn.to_s.end_with?("user/Lahiri")
      @operator_credentials = nil
      raise ArgumentError, "operator profile #{name} resolved to #{identity.arn}"
    end

    @operator_credentials = resolved
    ENV["VF5_F4_CALLER_ARN"] = identity.arn
    identity.arn
  end

  def self.operator_client_options
    raise ArgumentError, "operator profile was not loaded" unless @operator_credentials

    allocate.send(:build_aws_client_options, region: REGION, credentials: @operator_credentials)
  end

  def self.credentials_present?
    pair = ENV["AWS_ACCESS_KEY_ID"].present? && ENV["AWS_SECRET_ACCESS_KEY"].present?
    bearer = ENV["AWS_BEARER_TOKEN_BEDROCK"].present? || ENV["AWS_BEDROCK_BEARER_TOKEN"].present?
    stored = Rails.application.credentials.dig(:aws, :access_key_id).present? &&
      Rails.application.credentials.dig(:aws, :secret_access_key).present?
    pair || bearer || stored
  end

  def initialize(store:, agent:, kb_sync:, candidate_dir:, backup_dir:, evidence_dir:, runtime: nil, sleep_for: nil, poll_limit: 120, expected_count: 90, validate_sidecars: true, retrieve: true, rehydrate: true)
    @store = store
    @agent = agent
    @kb_sync = kb_sync
    @runtime = runtime
    @candidate_dir = Pathname(candidate_dir)
    @backup_dir = Pathname(backup_dir)
    @evidence_dir = Pathname(evidence_dir)
    @sleep_for = sleep_for || ->(seconds) { sleep(seconds) }
    @poll_limit = poll_limit
    @expected_count = expected_count
    @validate_sidecars = validate_sidecars
    @retrieve = retrieve
    @rehydrate = rehydrate
    @backup = nil
    @restore_started = false
    @sync_labels = []
    @report = {}
  end

  attr_reader :report

  def call
    FileUtils.mkdir_p(@evidence_dir)
    @report = {
      "region" => REGION,
      "bucket" => BUCKET,
      "prefix" => PREFIX,
      "knowledge_base_id" => KNOWLEDGE_BASE_ID,
      "data_source_id" => DATA_SOURCE_ID,
      "evidence_dir" => @evidence_dir.to_s,
      "aws_caller" => ENV["VF5_F4_CALLER_ARN"].presence
    }
    persist_report!
    load_candidate!
    resolve_data_source!
    assert_bucket!
    wait_until_idle!(stage: :read)
    backup_remote!
    note_review_copy!
    record_remote_difference!
    if @report["remote_candidate_match"]
      @report["rewrite"] = "skipped"
    else
      publish!
    end
    verify_published!
    invalidate_document_caches!
    sync_and_wait!
    record_check(:rehydrate) { rehydrate_published_target! if @rehydrate }
    record_check(:retrieve) { measure_retrieval! if @retrieve }
    @report["stopped"] = nil
    persist_report!
    @report
  rescue Stop => error
    handle_stop(error)
    persist_report!
    @report
  end

  private

  def load_candidate!
    manifest = JSON.parse(File.read(@candidate_dir.join("manifest.json")))
    raise Stop.new("candidate git_sha changed", stage: :read) unless manifest["git_sha"] == CANDIDATE_GIT_SHA

    files = manifest.fetch("files")
    raise Stop.new("candidate has #{files.size} files", stage: :read) unless files.size == @expected_count

    @candidate = files.map { |relative, sha| candidate_object(relative, sha) }
    @report["candidate_git_sha"] = manifest["git_sha"]
    @report["candidate_files"] = files.size
    target = @candidate.find { |object| object[:key] == TARGET_KEY }
    raise Stop.new("candidate is missing #{TARGET_KEY}", stage: :read) if target.nil? && @expected_count == 90
    raise Stop.new("candidate target sha differs", stage: :read) if target && target[:sha256] != TARGET_SHA
  end

  def candidate_object(relative, sha)
    path = @candidate_dir.join("kb", relative)
    body = File.binread(path)
    actual = Digest::SHA256.hexdigest(body)
    raise Stop.new("candidate bytes differ for #{relative}", stage: :read) unless actual == sha
    validate_sidecar!(relative, body) if @validate_sidecars && relative.end_with?(".metadata.json")
    { key: relative, body: body, sha256: sha, content_type: TEXT_TYPE }
  end

  def validate_sidecar!(relative, body)
    attributes = JSON.parse(body).fetch("metadataAttributes")
    missing = SIDECAR_KEYS.reject { |key| attributes[key].present? }
    raise Stop.new("#{relative} missing #{missing.join(', ')}", stage: :read) if missing.any?
    raise Stop.new("#{relative} ingestion_path", stage: :read) unless attributes["ingestion_path"] == "manual_batch_v1"
    raise Stop.new("#{relative} contract", stage: :read) unless attributes["ingestion_contract_version"] == "field_records_v8"
  end

  def resolve_data_source!
    resolved = @kb_sync.resolved_data_source_id
    raise Stop.new("configured data source #{DATA_SOURCE_ID} is not listed in #{KNOWLEDGE_BASE_ID}", stage: :read) unless resolved == DATA_SOURCE_ID

    @report["resolved_data_source_id"] = resolved
  end

  def assert_bucket!
    response = @agent.get_data_source(knowledge_base_id: KNOWLEDGE_BASE_ID, data_source_id: DATA_SOURCE_ID)
    s3 = response.data_source.data_source_configuration.s3_configuration
    bucket_arn = s3.bucket_arn.to_s
    prefixes = Array(s3.inclusion_prefixes).map(&:to_s)
    @report["data_source_bucket_arn"] = bucket_arn
    @report["data_source_prefixes"] = prefixes
    raise Stop.new("data source bucket is #{bucket_arn}", stage: :read) unless bucket_arn.include?(BUCKET)
    raise Stop.new("data source prefixes do not include #{PREFIX}", stage: :read) unless prefix_covered?(prefixes)
  rescue Stop
    raise
  rescue StandardError => error
    raise Stop.new("could not read data source #{DATA_SOURCE_ID}: #{error.class}: #{error.message}", stage: :read)
  end

  def prefix_covered?(prefixes)
    return true if prefixes.empty?

    directory = PREFIX.delete_suffix("/")
    prefixes.any? do |item|
      cleaned = item.delete_suffix("/")
      cleaned.blank? || directory.start_with?(cleaned) || cleaned.start_with?(directory)
    end
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
  rescue Stop
    raise
  rescue StandardError => error
    raise Stop.new("could not list ingestion jobs: #{error.class}: #{error.message}", stage: stage)
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
      token = response.respond_to?(:next_token) ? response.next_token : nil
      break if token.blank?
    end
    ids
  end

  def backup_remote!
    FileUtils.mkdir_p(@backup_dir.join("objects"))
    keys = @store.list_keys!(prefix: PREFIX).sort
    @backup = keys.map { |key| backup_object(key) }
    manifest = @backup.map { |record| record.except(:body) }
    File.write(@backup_dir.join("manifest.json"), JSON.generate(manifest))
    manifest.each do |record|
      stored = File.binread(@backup_dir.join("objects", record[:key]))
      raise Stop.new("backup cannot restore #{record[:key]}", stage: :read) unless Digest::SHA256.hexdigest(stored) == record[:sha256]
      raise Stop.new("backup metadata missing for #{record[:key]}", stage: :read) unless record.key?(:content_type) && record.key?(:metadata)
    end
    @report["previous_remote"] = @backup.to_h { |record| [ record[:key], record[:sha256] ] }
    @report["previous_remote_count"] = @backup.size
  rescue Stop
    raise
  rescue StandardError => error
    raise Stop.new("backup failed: #{error.class}: #{error.message}", stage: :read)
  end

  def backup_object(key)
    record = @store.object_record(key)
    raise Stop.new("could not read #{key}", stage: :read) if record.nil? || record[:body].nil?

    destination = @backup_dir.join("objects", key)
    FileUtils.mkdir_p(destination.dirname)
    File.binwrite(destination, record[:body])
    record.merge(sha256: Digest::SHA256.hexdigest(record[:body]))
  end

  def note_review_copy!
    root = Rails.root.join("tmp/review_vf5")
    @report["review_vf5"] = { "present" => false }
    return unless root.directory?

    remote = @report["previous_remote"]
    compared = {}
    Dir.glob(root.join("**/*")).select { |path| File.file?(path) }.each do |path|
      name = File.basename(path)
      key = remote.keys.find { |item| item.end_with?("/#{name}") || item == name }
      next unless key

      compared[key] = Digest::SHA256.file(path).hexdigest == remote[key]
    end
    @report["review_vf5"] = {
      "present" => true,
      "compared" => compared.size,
      "matches_remote" => compared.any? && compared.values.all?,
      "remote_keys" => remote.size
    }
  end

  def record_remote_difference!
    remote = @backup.to_h { |record| [ record[:key], record[:sha256] ] }
    candidate = @candidate.to_h { |object| [ object[:key], object[:sha256] ] }
    @report["remote_candidate_match"] = remote == candidate
    @report["remote_only_keys"] = (remote.keys - candidate.keys).sort
    @report["candidate_only_keys"] = (candidate.keys - remote.keys).sort
    @report["hash_mismatches"] = remote.keys.intersection(candidate.keys).select { |key| remote[key] != candidate[key] }.sort
  end

  def publish!
    @store.replace_prefix!(
      prefix: PREFIX,
      objects: @candidate.map { |object| object.slice(:key, :body, :content_type) }
    )
    @report["rewrite"] = "replaced"
  rescue Stop
    raise
  rescue StandardError => error
    raise Stop.new(error.message, stage: :write)
  end

  def verify_published!
    listed = @store.list_keys!(prefix: PREFIX)
    expected = @candidate.pluck(:key)
    raise Stop.new("published keys differ", stage: :write) unless listed.sort == expected.sort

    excluded = listed.select { |key| EXCLUDED.any? { |name| key.end_with?("/#{name}") || key.end_with?("/#{name}.metadata.json") } }
    raise Stop.new("excluded keys remain: #{excluded.join(', ')}", stage: :write) if excluded.any?

    target = @candidate.find { |object| object[:key] == TARGET_KEY }
    if target
      remote = @store.object_record(TARGET_KEY)
      raise Stop.new("published target unreadable", stage: :write) if remote.nil?

      digest = Digest::SHA256.hexdigest(remote[:body])
      raise Stop.new("published target sha #{digest}", stage: :write) unless digest == TARGET_SHA
      @report["target_sha256"] = digest
    end
    @report["published_sha256"] = @candidate.to_h { |object| [ object[:key], object[:sha256] ] }
  end

  def invalidate_document_caches!
    prefix = PREFIX.delete_suffix("/")
    neighbor = Rag::SectionNeighborExpander.index_cache_key(prefix)
    definition = Rag::CompanionDefinitionSource.cache_key(prefix)
    Rails.cache.write(neighbor, { "f4" => true })
    Rails.cache.write(definition, [ { "f4" => true } ])
    Rag::SectionNeighborExpander.invalidate!(prefix)
    Rag::CompanionDefinitionSource.invalidate!(prefix)
    @report["cache_invalidated"] = {
      "neighbor" => Rails.cache.read(neighbor).nil?,
      "definitions" => Rails.cache.read(definition).nil?,
      "store" => Rails.cache.class.name
    }
  end

  def sync_and_wait!
    start_sync!("sync")
  end

  def start_sync!(label)
    raise Stop.new("ingestion start already recorded", stage: :sync) if @sync_labels.include?(label)

    @sync_labels << label
    request = {
      "knowledge_base_id" => KNOWLEDGE_BASE_ID,
      "data_source_id" => DATA_SOURCE_ID,
      "label" => label
    }
    (@report["start_requests"] ||= []) << request
    @report["start_ingestion_job"] = request
    result = @kb_sync.sync!
    unless result.is_a?(Hash) && result[:job_id].present? && result[:data_source_id] == DATA_SOURCE_ID && result[:kb_id] == KNOWLEDGE_BASE_ID
      raise Stop.new("ingestion was not started on #{KNOWLEDGE_BASE_ID}/#{DATA_SOURCE_ID}", stage: :sync)
    end

    @report[label] = {
      "job_id" => result[:job_id],
      "knowledge_base_id" => result[:kb_id],
      "data_source_id" => result[:data_source_id]
    }
    snapshot = wait_for_job!(result[:job_id])
    @report["#{label}_result"] = snapshot
    return snapshot if snapshot["status"] == "COMPLETE" && !prefix_failure?(snapshot)

    raise Stop.new("ingestion #{result[:job_id]} finished #{snapshot['status']}", stage: :sync)
  end

  def wait_for_job!(job_id)
    last = nil
    @poll_limit.times do
      last = job_snapshot(job_id)
      (@report["job_polls"] ||= []) << last
      persist_report!
      return last if TERMINAL.include?(last["status"])

      @sleep_for.call(POLL_SECONDS)
    end
    raise Stop.new("ingestion #{job_id} still #{last&.dig('status')}", stage: :sync_running)
  rescue Stop
    raise
  rescue StandardError => error
    raise Stop.new("could not read ingestion #{job_id}: #{error.message}", stage: :sync_running)
  end

  def job_snapshot(job_id)
    response = @agent.get_ingestion_job(
      knowledge_base_id: KNOWLEDGE_BASE_ID,
      data_source_id: DATA_SOURCE_ID,
      ingestion_job_id: job_id
    )
    job = response.ingestion_job
    stats = job.statistics
    {
      "job_id" => job.ingestion_job_id.to_s,
      "status" => job.status.to_s,
      "failure_reasons" => Array(job.failure_reasons).map(&:to_s),
      "statistics" => {
        "scanned" => stats&.number_of_documents_scanned.to_i,
        "new_indexed" => stats&.number_of_new_documents_indexed.to_i,
        "modified_indexed" => stats&.number_of_modified_documents_indexed.to_i,
        "deleted" => stats&.number_of_documents_deleted.to_i,
        "failed" => stats&.number_of_documents_failed.to_i
      }
    }
  end

  def prefix_failure?(snapshot)
    snapshot["failure_reasons"].any? { |reason| reason.include?(PREFIX.delete_suffix("/")) }
  end

  def measure_retrieval!
    plan = retrieval_plan
    write_json("retrieval_plan.json", plan)
    @report["retrieval_plan"] = plan
    calls = []
    first = execute_retrieve(3)
    calls << first
    unless group_present?(first)
      second = execute_retrieve(5)
      calls << second
      rank = target_rank(second)
      if rank && rank >= 4 && retrieval_query_names_symptom?
        third = execute_retrieve(5)
        third["adjustment"] = "PINNED_DOCUMENT_RESULTS"
        calls << third
        @report["retrieval_adjustment"] = "PINNED_DOCUMENT_RESULTS from 3 to 5 is applicable; the third call uses the same query at k=5"
      end
    end
    write_json("retrieval_results.json", calls)
    @report["retrieval"] = calls.map { |call| call.merge("results" => call["results"].map { |row| row.except("content") }) }
  end

  def retrieval_plan
    {
      "query" => RETRIEVAL_QUERY,
      "symptom_named" => retrieval_query_names_symptom?,
      "truncated_without_symptom" => false,
      "query_composer_adjustment" => "not applicable",
      "reranking" => false,
      "filter" => PIN_URI,
      "calls" => [
        { "id" => 1, "number_of_results" => 3, "when" => "always" },
        { "id" => 2, "number_of_results" => 5, "when" => "group absent from the first three" },
        { "id" => 3, "number_of_results" => 5, "when" => "group at rank 4 or 5; same query after the allowed pinned-results adjustment" }
      ]
    }
  end

  def retrieval_query_names_symptom?
    RETRIEVAL_QUERY.include?("vuelve a abrirse sola")
  end

  def execute_retrieve(number_of_results)
    request = retrieval_request(number_of_results)
    raise Stop.new("reranking was included", stage: :retrieve) if request.key?(:reranking_configuration) || request.dig(:retrieval_configuration, :vector_search_configuration).key?(:reranking_configuration)

    response = @runtime.retrieve(request)
    results = Array(response.retrieval_results).each_with_index.map { |result, index| serialize_result(result, index + 1) }
    {
      "number_of_results" => number_of_results,
      "request" => {
        "knowledge_base_id" => KNOWLEDGE_BASE_ID,
        "query" => RETRIEVAL_QUERY,
        "number_of_results" => number_of_results,
        "override_search_type" => "HYBRID",
        "reranking" => false
      },
      "results" => results
    }
  end

  def retrieval_request(number_of_results)
    {
      knowledge_base_id: KNOWLEDGE_BASE_ID,
      retrieval_query: { text: RETRIEVAL_QUERY },
      retrieval_configuration: {
        vector_search_configuration: {
          number_of_results: number_of_results,
          override_search_type: "HYBRID",
          filter: {
            or_all: [
              { equals: { key: "x-amz-bedrock-kb-source-uri", value: PIN_URI } },
              { equals: { key: "original_source_uri", value: PIN_URI } }
            ]
          }
        }
      }
    }
  end

  def serialize_result(result, rank)
    content = result.content&.text.to_s
    uri = result.location&.s3_location&.uri.to_s
    metadata = result.metadata.respond_to?(:to_h) ? result.metadata.to_h : {}
    {
      "rank" => rank,
      "score" => result.score,
      "uri" => uri,
      "filename" => uri.split("/").last.to_s,
      "metadata" => metadata.to_h { |key, value| [ key.to_s, value.to_s ] },
      "content" => content,
      "content_sha256" => Digest::SHA256.hexdigest(content),
      "phrases" => GROUP_PHRASES.index_with { |phrase| content.include?(phrase) }.merge(NEXT_SYMPTOM => content.include?(NEXT_SYMPTOM))
    }
  end

  def group_present?(call)
    Array(call["results"]).any? { |row| target_row?(row) }
  end

  def target_rank(call)
    row = Array(call["results"]).find { |item| target_row?(item) }
    row&.dig("rank")
  end

  def target_row?(row)
    row["filename"] == "chunk_p12_5.txt" || row["uri"].to_s.end_with?("/chunk_p12_5.txt") || row["content"].to_s.include?("La puerta se re-abre sola")
  end

  def rehydrate_published_target!
    prefix = PREFIX.delete_suffix("/")
    Rails.cache.delete(Rag::CompanionDefinitionSource.cache_key(prefix))
    Rag::CompanionDefinitionCatalog.current = nil
    probe = {
      location_uri: "s3://#{BUCKET}/#{prefix}/chunk_p1_1.txt",
      content: "probe",
      metadata: { "original_source_uri" => PIN_URI, "filename" => "chunk_p1_1.txt" }
    }
    source = Rag::CompanionDefinitionSource.new(store_for: lambda { |bucket|
      raise Stop.new("catalog bucket #{bucket}", stage: :rehydrate) unless bucket == BUCKET

      @store
    })
    catalog = source.catalog_for([ probe ])
    target = {
      "item" => "La puerta se re-abre sola.",
      "page" => "12",
      "filename" => "chunk_p12_5.txt",
      "document_key" => PIN_URI
    }
    result = Rag::CompanionDefinitionExpander.expand([ probe ], catalog: catalog, targets: [ target ])
    loaded = result.added.find { |row| row["filename"] == "chunk_p12_5.txt" }
    omitted = result.omitted.select { |row| row["reason"] == "target_not_loaded" }
    @report["rehydration"] = {
      "catalog" => catalog.nil? ? "absent" : "present",
      "added_filename" => loaded&.dig("filename"),
      "added_text_sha256" => loaded&.dig("sha256"),
      "stored_body_sha256" => TARGET_SHA,
      "omitted" => omitted,
      "rendered_limit" => omission_sentence(omitted)
    }
  end

  def omission_sentence(omitted)
    return nil if omitted.empty?

    check = Struct.new(:links, :steps, :question, :omissions).new([], [], nil, omitted)
    facts = Struct.new(:facts).new([])
    statements = Struct.new(:statements).new([])
    Rag::CompanionPlanRender.call(check, facts: facts, statements: statements)
  end

  def handle_stop(error)
    @report["stopped"] = { "stage" => error.stage.to_s, "message" => error.message }
    return unless !@restore_started && %i[write sync].include?(error.stage) && @backup

    begin
      restore_once!(error.message)
    rescue Stop => restore_error
      @report["restore_stopped"] = { "stage" => restore_error.stage.to_s, "message" => restore_error.message }
      @report["remote_keys_after_failed_restore"] = safe_remote_keys
    end
  end

  def restore_once!(reason)
    raise Stop.new("restore already attempted", stage: :restore) if @restore_started

    @restore_started = true
    @report["restore_reason"] = reason
    wait_until_idle!(stage: :restore)
    @store.restore_prefix!(prefix: PREFIX, records: @backup)
    verify_restored!
    invalidate_document_caches!
    start_sync!("resync")
  end

  def verify_restored!
    @backup.each do |record|
      remote = @store.object_record(record[:key])
      raise Stop.new("restored object unreadable #{record[:key]}", stage: :restore) if remote.nil?

      digest = Digest::SHA256.hexdigest(remote[:body])
      raise Stop.new("restored bytes differ #{record[:key]}", stage: :restore) unless digest == record[:sha256]
      raise Stop.new("restored content type differs #{record[:key]}", stage: :restore) unless remote[:content_type].to_s == record[:content_type].to_s

      left = remote.fetch(:metadata, {}).to_h.transform_keys(&:to_s)
      right = record.fetch(:metadata, {}).to_h.transform_keys(&:to_s)
      raise Stop.new("restored metadata differs #{record[:key]}", stage: :restore) unless left == right
    end
    @report["restored"] = true
  end

  def safe_remote_keys
    @store.list_keys!(prefix: PREFIX)
  rescue StandardError => error
    [ "list failed: #{error.message}" ]
  end

  def record_check(stage)
    yield
  rescue Stop => error
    @report["#{stage}_stopped"] = { "stage" => error.stage.to_s, "message" => error.message }
  rescue StandardError => error
    @report["#{stage}_stopped"] = { "stage" => stage.to_s, "message" => "#{error.class}: #{error.message}" }
  end

  def persist_report!
    write_json("report.json", @report)
  end

  def write_json(name, payload)
    FileUtils.mkdir_p(@evidence_dir)
    File.write(@evidence_dir.join(name), JSON.generate(payload))
  end
end
