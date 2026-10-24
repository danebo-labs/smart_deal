# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "ostruct"
require "securerandom"

class Vf5F4PublicationTest < ActiveSupport::TestCase
  PREFIX = Vf5F4Publication::PREFIX
  KEY = "#{PREFIX}chunk_p1_1.txt"
  OTHER = "#{PREFIX}chunk_p2_1.txt"

  class FakeStore
    attr_reader :replace_calls, :restore_calls
    attr_accessor :bucket_name, :fail_replace

    def initialize(records)
      @objects = records
      @bucket_name = Vf5F4Publication::BUCKET
      @replace_calls = 0
      @restore_calls = 0
      @fail_replace = false
    end

    def list_keys!(prefix:)
      @objects.keys.select { |key| key.start_with?(prefix) }
    end

    def list_keys(prefix:)
      list_keys!(prefix: prefix)
    end

    def object_record(key)
      found = @objects[key]
      return nil unless found

      found.merge(key: key)
    end

    def download(key)
      @objects.dig(key, :body)
    end

    def replace_prefix!(prefix:, objects:)
      raise S3DocumentsService::IncompleteReplacement, "delete left 1 objects under #{prefix}" if @fail_replace

      @replace_calls += 1
      @objects = objects.to_h { |object| [ object[:key], object.slice(:body, :content_type).merge(metadata: {}) ] }
      objects.pluck(:key)
    end

    def restore_prefix!(prefix:, records:)
      @restore_calls += 1
      @objects = records.to_h { |record| [ record[:key], record.slice(:body, :content_type, :metadata) ] }
      records.pluck(:key)
    end
  end

  class FakeAgent
    attr_accessor :jobs, :statuses, :prefixes

    def initialize
      @jobs = []
      @statuses = [ "COMPLETE" ]
      @prefixes = [ "bulk_chunks/" ]
      @index = 0
    end

    def get_data_source(**_params)
      OpenStruct.new(
        data_source: OpenStruct.new(
          data_source_configuration: OpenStruct.new(
            s3_configuration: OpenStruct.new(
              bucket_arn: "arn:aws:s3:::#{Vf5F4Publication::BUCKET}",
              inclusion_prefixes: @prefixes
            )
          )
        )
      )
    end

    def list_ingestion_jobs(**_params)
      OpenStruct.new(ingestion_job_summaries: @jobs, next_token: nil)
    end

    def get_ingestion_job(**params)
      status = @statuses[@index] || @statuses.last
      @index += 1
      OpenStruct.new(
        ingestion_job: OpenStruct.new(
          ingestion_job_id: params[:ingestion_job_id],
          status: status,
          failure_reasons: [],
          statistics: OpenStruct.new(
            number_of_documents_scanned: 4,
            number_of_new_documents_indexed: 1,
            number_of_modified_documents_indexed: 1,
            number_of_documents_deleted: 0,
            number_of_documents_failed: 0
          )
        )
      )
    end
  end

  class FakeSync
    attr_reader :calls
    attr_accessor :resolved, :mode

    def initialize
      @resolved = Vf5F4Publication::DATA_SOURCE_ID
      @calls = []
      @mode = :ok
    end

    def resolved_data_source_id
      @resolved
    end

    def sync!
      @calls << true
      return nil if @mode == :nil_once && @calls.size == 1

      {
        job_id: "job-#{@calls.size}",
        kb_id: Vf5F4Publication::KNOWLEDGE_BASE_ID,
        data_source_id: Vf5F4Publication::DATA_SOURCE_ID
      }
    end
  end

  class FakeRuntime
    attr_reader :calls, :requests

    def initialize(mode)
      @mode = mode
      @calls = []
      @requests = []
    end

    def retrieve(request)
      k = request.dig(:retrieval_configuration, :vector_search_configuration, :number_of_results)
      @calls << k
      @requests << request
      OpenStruct.new(retrieval_results: results_for(k))
    end

    private

    def results_for(k)
      other = result("s3://#{Vf5F4Publication::BUCKET}/#{OTHER}", "otra puerta", 0.2)
      target = result("s3://#{Vf5F4Publication::BUCKET}/#{Vf5F4Publication::TARGET_KEY}", "La puerta se re-abre sola", 0.4)
      rows = case @mode
      when :hit
        [ target, other, other ]
      when :rank4
        [ other, other, other, target, other ]
      else
        k == 3 ? [ other, other, other ] : [ target, other, other, other, other ]
      end
      rows.first(k)
    end

    def result(uri, text, score)
      OpenStruct.new(
        score: score,
        metadata: { "original_source_uri" => Vf5F4Publication::PIN_URI },
        content: OpenStruct.new(text: text),
        location: OpenStruct.new(s3_location: OpenStruct.new(uri: uri))
      )
    end
  end

  test "operator profile keeps the caller credentials on the clients" do
    original_caller = ENV["VF5_F4_CALLER_ARN"]
    creds = Object.new
    creds.define_singleton_method(:set?) { true }
    creds.define_singleton_method(:session_token) { nil }
    provider = Object.new
    provider.define_singleton_method(:credentials) { creds }
    original_shared = Aws::SharedCredentials.method(:new)
    original_sts = Aws::STS::Client.method(:new)
    Aws::SharedCredentials.define_singleton_method(:new) { |*| provider }
    sts = Object.new
    sts.define_singleton_method(:get_caller_identity) { OpenStruct.new(arn: "arn:aws:iam::935142957735:user/Lahiri") }
    Aws::STS::Client.define_singleton_method(:new) { |*| sts }

    arn = Vf5F4Publication.use_operator_profile!

    assert_equal "arn:aws:iam::935142957735:user/Lahiri", arn
    assert_equal creds, Vf5F4Publication.operator_client_options[:credentials]
    assert_equal "us-east-1", Vf5F4Publication.operator_client_options[:region]
    assert_not Vf5F4Publication.operator_client_options.key?(:access_key_id)
  ensure
    Aws::SharedCredentials.define_singleton_method(:new) { |*args, **kwargs| original_shared.call(*args, **kwargs) }
    Aws::STS::Client.define_singleton_method(:new) { |*args, **kwargs| original_sts.call(*args, **kwargs) }
    Vf5F4Publication.instance_variable_set(:@operator_credentials, nil)
    original_caller.nil? ? ENV.delete("VF5_F4_CALLER_ARN") : ENV["VF5_F4_CALLER_ARN"] = original_caller
  end

  test "operator profile stops when the profile is not the operator" do
    creds = Object.new
    creds.define_singleton_method(:set?) { true }
    creds.define_singleton_method(:session_token) { nil }
    provider = Object.new
    provider.define_singleton_method(:credentials) { creds }
    original_shared = Aws::SharedCredentials.method(:new)
    original_sts = Aws::STS::Client.method(:new)
    Aws::SharedCredentials.define_singleton_method(:new) { |*| provider }
    sts = Object.new
    sts.define_singleton_method(:get_caller_identity) { OpenStruct.new(arn: "arn:aws:iam::935142957735:user/bedrock-integration-user") }
    Aws::STS::Client.define_singleton_method(:new) { |*| sts }

    assert_raises(ArgumentError) { Vf5F4Publication.use_operator_profile! }
    assert_raises(ArgumentError) { Vf5F4Publication.operator_client_options }
  ensure
    Aws::SharedCredentials.define_singleton_method(:new) { |*args, **kwargs| original_shared.call(*args, **kwargs) }
    Aws::STS::Client.define_singleton_method(:new) { |*args, **kwargs| original_sts.call(*args, **kwargs) }
    Vf5F4Publication.instance_variable_set(:@operator_credentials, nil)
  end

  test "operator profile refuses a temporary session" do
    creds = Object.new
    creds.define_singleton_method(:set?) { true }
    creds.define_singleton_method(:session_token) { "temporary" }
    provider = Object.new
    provider.define_singleton_method(:credentials) { creds }
    original_shared = Aws::SharedCredentials.method(:new)
    Aws::SharedCredentials.define_singleton_method(:new) { |*| provider }

    assert_raises(ArgumentError) { Vf5F4Publication.use_operator_profile! }
  ensure
    Aws::SharedCredentials.define_singleton_method(:new) { |*args, **kwargs| original_shared.call(*args, **kwargs) }
  end

  setup do
    @root = Rails.root.join("tmp/vf5_f4_publication_test/#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@root)
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "does not write or sync when the configured data source is absent" do
    sync = FakeSync.new
    sync.resolved = nil
    report = publish(remote: { KEY => "old" }, candidate: { KEY => "new" }, sync: sync)

    assert_equal "read", report["stopped"]["stage"]
    assert_equal 0, report_store.replace_calls
    assert_empty sync.calls
  end

  test "does not write when the data source prefix is different" do
    agent = FakeAgent.new
    agent.prefixes = [ "other-manual/" ]
    report = publish(remote: { KEY => "old" }, candidate: { KEY => "new" }, agent: agent)

    assert_equal "read", report["stopped"]["stage"]
    assert_equal 0, report_store.replace_calls
  end

  test "does not write while an ingestion job stays active" do
    agent = FakeAgent.new
    agent.jobs = [ OpenStruct.new(ingestion_job_id: "busy", status: "IN_PROGRESS") ]
    sleeps = []
    report = publish(remote: { KEY => "old" }, candidate: { KEY => "new" }, agent: agent, sleep_for: ->(seconds) { sleeps << seconds }, poll_limit: 1)

    assert_equal "read", report["stopped"]["stage"]
    assert_equal [ 30 ], sleeps
    assert_equal 0, report_store.replace_calls
    assert_empty report_sync.calls
  end

  test "skips rewrite when remote bytes already match and syncs once" do
    report = publish(remote: { KEY => "same", OTHER => "two" }, candidate: { KEY => "same", OTHER => "two" })

    assert_nil report["stopped"]
    assert_equal "skipped", report["rewrite"]
    assert_equal 0, report_store.replace_calls
    assert_equal 1, report_sync.calls.size
    assert_equal "job-1", report.dig("sync", "job_id")
    assert_equal "COMPLETE", report.dig("sync_result", "status")
    assert_equal 4, report.dig("sync_result", "statistics", "scanned")
  end

  test "replaces a different prefix and does not sync again" do
    report = publish(remote: { KEY => "old" }, candidate: { KEY => "new" })

    assert_nil report["stopped"]
    assert_equal "replaced", report["rewrite"]
    assert_equal 1, report_store.replace_calls
    assert_equal 0, report_store.restore_calls
    assert_equal 1, report_sync.calls.size
    assert report["cache_invalidated"]["neighbor"]
    assert report["cache_invalidated"]["definitions"]
  end

  test "restores once and resyncs once when the replacement stops" do
    store = store_for(KEY => "old")
    store.fail_replace = true
    report = publish(remote: { KEY => "old" }, candidate: { KEY => "new" }, store: store)

    assert_equal "write", report["stopped"]["stage"]
    assert_equal 1, store.restore_calls
    assert_equal 1, report_sync.calls.size
    assert_equal "job-1", report.dig("resync", "job_id")
    assert report["restored"]
  end

  test "restores when the ingestion job is not started and does not start a third job" do
    sync = FakeSync.new
    sync.mode = :nil_once
    report = publish(remote: { KEY => "old" }, candidate: { KEY => "new" }, sync: sync)

    assert_equal "sync", report["stopped"]["stage"]
    assert_equal 2, sync.calls.size
    assert report["restored"]
    assert_equal "COMPLETE", report.dig("resync_result", "status")
  end

  test "restores when the ingestion job fails and resyncs once" do
    agent = FakeAgent.new
    agent.statuses = [ "FAILED", "COMPLETE" ]
    report = publish(remote: { KEY => "old" }, candidate: { KEY => "new" }, agent: agent)

    assert_equal "sync", report["stopped"]["stage"]
    assert_equal 2, report_sync.calls.size
    assert_equal "COMPLETE", report.dig("resync_result", "status")
  end

  test "retrieval stops at k=3 when the group is already present" do
    runtime = FakeRuntime.new(:hit)
    report = publish(remote: { KEY => "same" }, candidate: { KEY => "same" }, runtime: runtime, retrieve: true)

    assert_equal [ 3 ], runtime.calls
    assert_equal Vf5F4Publication::RETRIEVAL_QUERY, runtime.requests.first.dig(:retrieval_query, :text)
    assert_not runtime.requests.first.dig(:retrieval_configuration, :vector_search_configuration).key?(:reranking_configuration)
    assert_equal [ "chunk_p12_5.txt" ], report.dig("retrieval", 0, "results").pluck("filename").grep("chunk_p12_5.txt")
    assert_nil report["retrieval_adjustment"]
  end

  test "retrieval uses k=5 when the group is absent and does not add a third call at rank 1" do
    runtime = FakeRuntime.new(:later)
    report = publish(remote: { KEY => "same" }, candidate: { KEY => "same" }, runtime: runtime, retrieve: true)

    assert_equal [ 3, 5 ], runtime.calls
    assert_nil report["retrieval_adjustment"]
  end

  test "retrieval makes the third call only when the group is at rank 4 or 5" do
    runtime = FakeRuntime.new(:rank4)
    report = publish(remote: { KEY => "same" }, candidate: { KEY => "same" }, runtime: runtime, retrieve: true)

    assert_equal [ 3, 5, 5 ], runtime.calls
    assert_match(/PINNED_DOCUMENT_RESULTS/, report["retrieval_adjustment"])
    assert_equal "PINNED_DOCUMENT_RESULTS", report.dig("retrieval", 2, "adjustment")
  end

  test "rehydrates the published target from the real catalog components" do
    body = Rails.root.join("tmp/field_companion/vf5_correction/f2f3_joint/f2/candidate_r2/kb/#{Vf5F4Publication::TARGET_KEY}").binread
    page = Rails.root.join("tmp/field_companion/vf5_correction/f2f3_joint/f2/candidate_r2/kb/#{KEY}").binread
    report = publish(
      remote: { KEY => page, Vf5F4Publication::TARGET_KEY => body },
      candidate: { KEY => page, Vf5F4Publication::TARGET_KEY => body },
      rehydrate: true
    )

    assert_nil report["stopped"], report.dig("stopped", "message")
    assert_equal "present", report.dig("rehydration", "catalog")
    assert_equal "chunk_p12_5.txt", report.dig("rehydration", "added_filename")
    assert_empty report.dig("rehydration", "omitted")
    assert_nil report.dig("rehydration", "rendered_limit")
    assert_equal Vf5F4Publication::TARGET_SHA, report.dig("rehydration", "stored_body_sha256")
  end

  test "shows the unloaded-section sentence when the catalog cannot load the target" do
    report = publish(remote: { KEY => "solo la portada" }, candidate: { KEY => "solo la portada" }, rehydrate: true)

    assert_nil report["stopped"], report.dig("stopped", "message")
    assert_equal "present", report.dig("rehydration", "catalog")
    assert_nil report.dig("rehydration", "added_filename")
    assert_equal "target_not_loaded", report.dig("rehydration", "omitted", 0, "reason")
    assert_includes report.dig("rehydration", "rendered_limit"), "no está en la documentación cargada en este turno"
  end

  private

  attr_reader :report_store, :report_sync

  def publish(remote:, candidate:, store: nil, agent: nil, sync: nil, runtime: nil, sleep_for: nil, poll_limit: 3, retrieve: false, rehydrate: false)
    @report_sync = sync || FakeSync.new
    @report_store = store || store_for(remote)
    directory = @root.join(SecureRandom.hex(2))
    write_candidate(directory.join("candidate"), candidate)
    Vf5F4Publication.call(
      store: @report_store,
      agent: agent || FakeAgent.new,
      kb_sync: @report_sync,
      runtime: runtime,
      candidate_dir: directory.join("candidate"),
      backup_dir: directory.join("restore"),
      evidence_dir: directory.join("evidence"),
      sleep_for: sleep_for || ->(_seconds) { },
      poll_limit: poll_limit,
      expected_count: candidate.size,
      validate_sidecars: false,
      retrieve: retrieve,
      rehydrate: rehydrate
    )
  end

  def store_for(remote)
    records = remote.to_h { |key, body| [ key, { body: body, content_type: "text/plain", metadata: {} } ] }
    FakeStore.new(records)
  end

  def write_candidate(dir, files)
    files.each do |key, body|
      path = dir.join("kb", key)
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, body)
    end
    manifest = {
      "git_sha" => Vf5F4Publication::CANDIDATE_GIT_SHA,
      "files" => files.to_h { |key, body| [ key, Digest::SHA256.hexdigest(body) ] }
    }
    File.write(dir.join("manifest.json"), JSON.generate(manifest))
  end
end
