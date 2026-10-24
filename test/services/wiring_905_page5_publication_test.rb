# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "ostruct"
require "tmpdir"

class Wiring905Page5PublicationTest < ActiveSupport::TestCase
  PUB = Wiring905Page5Publication
  PREFIX = PUB::PREFIX
  TEXT = "text/plain; charset=utf-8"

  Stats = Struct.new(
    :number_of_documents_scanned,
    :number_of_metadata_documents_scanned,
    :number_of_new_documents_indexed,
    :number_of_modified_documents_indexed,
    :number_of_metadata_documents_modified,
    :number_of_documents_deleted,
    :number_of_documents_failed,
    keyword_init: true
  )

  class FakeRemote
    attr_reader :puts, :deletes
    attr_accessor :touch_other

    def initialize(objects)
      @objects = objects
      @summaries = objects.to_h do |key, record|
        [ key, { "etag" => "etag-#{key.hash}", "size" => record[:body].bytesize, "last_modified" => "2026-08-24T13:57:22.000000Z" } ]
      end
      @puts = []
      @deletes = []
      @touch_other = false
    end

    def list_object_summaries!(prefix:)
      @summaries.filter_map { |key, row| row.merge("key" => key) if key.start_with?(prefix) }
    end

    def object_record(key)
      found = @objects[key]
      return nil unless found

      found.merge(key: key)
    end

    def upload_binary(key, body, content_type)
      @puts << key
      @objects[key] = { body: body, content_type: content_type, metadata: {}, content_encoding: nil }
      @summaries[key] = { "etag" => "new-#{body.bytesize}", "size" => body.bytesize, "last_modified" => "2026-10-24T15:30:00.000000Z" }
      if @touch_other
        other = "#{PREFIX}chunk_p4_1.txt"
        @summaries[other] = @summaries[other].merge("etag" => "changed-by-someone-else")
      end
      key
    end

    def delete_object!(key)
      @deletes << key
      @objects.delete(key)
      @summaries.delete(key)
      key
    end
  end

  class FakeAgent
    attr_reader :starts

    attr_accessor :strategy, :model, :prefixes, :aurora_failures

    def initialize
      @starts = []
      @jobs = []
      @responses = []
      @strategy = "NONE"
      @model = "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
      @prefixes = [ "bulk_chunks/" ]
      @aurora_failures = 0
    end

    def get_data_source(**)
      OpenStruct.new(
        data_source: OpenStruct.new(
          data_source_configuration: OpenStruct.new(
            s3_configuration: OpenStruct.new(
              bucket_arn: "arn:aws:s3:::#{PUB::BUCKET}",
              inclusion_prefixes: @prefixes
            )
          ),
          vector_ingestion_configuration: OpenStruct.new(
            chunking_configuration: OpenStruct.new(chunking_strategy: @strategy)
          )
        )
      )
    end

    def get_knowledge_base(**)
      OpenStruct.new(
        knowledge_base: OpenStruct.new(
          knowledge_base_configuration: OpenStruct.new(
            vector_knowledge_base_configuration: OpenStruct.new(embedding_model_arn: @model)
          )
        )
      )
    end

    def list_ingestion_jobs(**)
      OpenStruct.new(ingestion_job_summaries: @jobs, next_token: nil)
    end

    def start_ingestion_job(knowledge_base_id:, data_source_id:)
      if @aurora_failures.positive?
        @aurora_failures -= 1
        raise Aws::BedrockAgent::Errors::ServiceError.new(nil, "The Aurora DB instance is resuming after being auto-paused")
      end

      @starts << { "knowledge_base_id" => knowledge_base_id, "data_source_id" => data_source_id }
      job(id: "JOB#{@starts.size}", status: "STARTING", reasons: [], failed: 0)
    end

    def get_ingestion_job(**params)
      response = @responses.shift || job(id: params[:ingestion_job_id], status: "COMPLETE", reasons: [], failed: 0)
      response.ingestion_job.ingestion_job_id = params[:ingestion_job_id]
      response
    end

    def queue(*items)
      @responses = items
    end

    def running!(id)
      @jobs = [ OpenStruct.new(ingestion_job_id: id, status: "STARTING") ]
    end

    def job(id:, status:, reasons:, failed:)
      OpenStruct.new(
        ingestion_job: OpenStruct.new(
          ingestion_job_id: id,
          knowledge_base_id: PUB::KNOWLEDGE_BASE_ID,
          data_source_id: PUB::DATA_SOURCE_ID,
          status: status,
          failure_reasons: reasons,
          statistics: Stats.new(
            number_of_documents_scanned: 4,
            number_of_metadata_documents_scanned: 4,
            number_of_new_documents_indexed: 2,
            number_of_modified_documents_indexed: 1,
            number_of_metadata_documents_modified: 2,
            number_of_documents_deleted: 0,
            number_of_documents_failed: failed
          )
        )
      )
    end
  end

  class FakeSync
    def resolved_data_source_id
      PUB::DATA_SOURCE_ID
    end
  end

  setup do
    @body = Rails.root.join("test/fixtures/files/wiring_905/chunk_p5_1.txt").binread
    @sidecar = Rails.root.join("test/fixtures/files/wiring_905/chunk_p5_1.txt.metadata.json").binread
    @remote = FakeRemote.new(remote_objects)
    @agent = FakeAgent.new
    @dir = Pathname(Dir.mktmpdir("wiring905"))
    @invalidated = []
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir
  end

  test "publishes the three fragments and two new sidecars when the job admits them" do
    report = publish
    created = PUB::CREATED_NAMES.map { |name| "#{PREFIX}#{name}" }

    assert_equal "accepted", report["verdict"]
    assert_equal [ "#{PREFIX}chunk_p5_1.txt" ] + created, @remote.puts
    assert_empty @remote.deletes
    assert_equal [ PUB::DATA_SOURCE_ID ], @agent.starts.pluck("data_source_id")
    assert_equal [ PUB::KNOWLEDGE_BASE_ID ], @agent.starts.pluck("knowledge_base_id")
    assert_equal PUB::SOURCE_SHA256, report.dig("backup", "objects", 0, "sha256")
    assert_equal PUB::SIDECAR_SHA256, report.dig("backup", "objects", 1, "sha256")
    assert_equal created, report.dig("backup", "absent")
    assert_equal "shared", report.dig("sidecar_review", "decision")
    assert report["titan_token_estimates_are_not_measurements"]
    assert_equal 3, report["prefix_count_before"]
    assert_equal 7, report["prefix_count_after"]
    assert_equal 2, report["unchanged_key_count"]
    assert_equal PUB::FRAGMENT_SHA256["chunk_p5_2.txt"], Digest::SHA256.hexdigest(@remote.object_record("#{PREFIX}chunk_p5_2.txt")[:body])
    assert_equal @sidecar, @remote.object_record("#{PREFIX}chunk_p5_1.txt.metadata.json")[:body]
    assert_equal [ PREFIX.delete_suffix("/") ], @invalidated.uniq
    assert @invalidated.none? { |prefix| prefix.include?(PUB::VF5_MARKER) }
    assert report["backup"]["readable"]
    assert_equal PUB::SOURCE_SHA256, Digest::SHA256.file(@dir.join("restore/objects/#{PREFIX}chunk_p5_1.txt")).hexdigest
  end

  test "stops before writing when chunking is not NONE" do
    @agent.strategy = "FIXED_SIZE"

    report = publish

    assert_equal "impediment", report["verdict"]
    assert_empty @remote.puts
    assert_equal "read", report.dig("stopped", "stage")
    assert_match(/FIXED_SIZE/, report.dig("stopped", "message"))
  end

  test "stops before writing when a new key already has different bytes" do
    @remote.upload_binary("#{PREFIX}chunk_p5_2.txt", "different", TEXT)
    @remote.puts.clear

    report = publish

    assert_equal "impediment", report["verdict"]
    assert_empty @remote.puts
    assert_match(/chunk_p5_2.txt exists/, report.dig("stopped", "message"))
  end

  test "stops before writing when an ingestion job is active" do
    @agent.running!("BUSY")

    report = publish

    assert_equal "impediment", report["verdict"]
    assert_empty @remote.puts
    assert_empty @agent.starts
    assert_match(/still active/, report.dig("stopped", "message"))
  end

  test "restores the original body and deletes only keys this run created" do
    reason = "Encountered error: request input token count: 9048. Issue occurred while processing file: #{PREFIX}chunk_p5_2.txt."
    @agent.queue(
      @agent.job(id: "JOB1", status: "COMPLETE", reasons: [ reason ], failed: 1),
      @agent.job(id: "JOB2", status: "COMPLETE", reasons: [ "9048 #{PREFIX}chunk_p5_1.txt" ], failed: 1)
    )

    report = publish

    created = PUB::CREATED_NAMES.map { |name| "#{PREFIX}#{name}" }

    assert_equal "restored", report["verdict"]
    assert_not report["size_error_resolved"]
    assert_match(/no corrige ese error/, report["restored_state"])
    assert report["resync_known_size_error"]
    assert_equal 2, @agent.starts.size
    assert_equal [ "#{PREFIX}chunk_p5_1.txt", *created, "#{PREFIX}chunk_p5_1.txt" ], @remote.puts
    assert_equal created, @remote.deletes
    assert_equal PUB::SOURCE_SHA256, Digest::SHA256.hexdigest(@remote.object_record("#{PREFIX}chunk_p5_1.txt")[:body])
    assert_equal @sidecar, @remote.object_record("#{PREFIX}chunk_p5_1.txt.metadata.json")[:body]
    assert_nil @remote.object_record("#{PREFIX}chunk_p5_2.txt")
    assert_equal "other", @remote.object_record("#{PREFIX}chunk_p4_1.txt")[:body]
  end

  test "records a foreign failure and leaves the published fragments" do
    @agent.queue(@agent.job(
      id: "JOB1",
      status: "COMPLETE",
      reasons: [ "Issue occurred while processing file: #{PREFIX}chunk_p12_1.txt." ],
      failed: 1
    ))

    report = publish

    assert_equal "accepted", report["verdict"]
    assert_empty @remote.deletes
    assert_equal 1, report["foreign_failures"].size
    assert_equal PUB::FRAGMENT_SHA256["chunk_p5_3.txt"], Digest::SHA256.hexdigest(@remote.object_record("#{PREFIX}chunk_p5_3.txt")[:body])
    assert_equal 1, @agent.starts.size
  end

  test "restores when another key in the prefix changes and does not revert that key" do
    @remote.touch_other = true
    @agent.queue(@agent.job(id: "JOB2", status: "COMPLETE", reasons: [], failed: 0))

    report = publish

    assert_equal "restored", report["verdict"]
    assert_match(/other keys changed/, report.dig("stopped", "message"))
    assert_equal PUB::SOURCE_SHA256, Digest::SHA256.hexdigest(@remote.object_record("#{PREFIX}chunk_p5_1.txt")[:body])
    assert_nil @remote.object_record("#{PREFIX}chunk_p5_3.txt")
    assert_equal "changed-by-someone-else", @remote.list_object_summaries!(prefix: PREFIX).find { |row| row["key"].end_with?("chunk_p4_1.txt") }["etag"]
  end

  test "waits out an Aurora resume and starts one ingestion job" do
    @agent.aurora_failures = 1
    original = Bedrock::AuroraColdStartRetry.method(:sleep_for)
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for) { |_seconds| }
    report = publish

    assert_equal "accepted", report["verdict"]
    assert_equal 1, @agent.starts.size
    assert_equal [ { "attempt" => 1, "delay_seconds" => 15 } ], report["aurora_retries"]
  ensure
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for, original) if original
  end

  test "resumes a verified upload with one sync and does not upload again" do
    publish_fragments!
    result = resume_publication

    assert_equal "accepted", result["verdict"]
    assert_equal "sync_only", result["resume"]
    assert_empty @remote.puts
    assert_equal 1, @agent.starts.size
    assert_equal PUB::FRAGMENT_SHA256["chunk_p5_1.txt"], Digest::SHA256.hexdigest(@remote.object_record("#{PREFIX}chunk_p5_1.txt")[:body])
  end

  test "a resumed sync that rejects a fragment restores the backed up body" do
    publish_fragments!
    reason = "Issue occurred while processing file: #{PREFIX}chunk_p5_2.txt."
    @agent.queue(
      @agent.job(id: "JOB1", status: "COMPLETE", reasons: [ reason ], failed: 1),
      @agent.job(id: "JOB2", status: "COMPLETE", reasons: [], failed: 0)
    )

    result = resume_publication

    assert_equal "restored", result["verdict"]
    assert_not result["size_error_resolved"]
    assert_equal [ "#{PREFIX}chunk_p5_1.txt" ], @remote.puts
    assert_equal PUB::CREATED_NAMES.map { |name| "#{PREFIX}#{name}" }, @remote.deletes
    assert_equal PUB::SOURCE_SHA256, Digest::SHA256.hexdigest(@remote.object_record("#{PREFIX}chunk_p5_1.txt")[:body])
  end

  private

  def resume_publication
    seen = @invalidated
    expander = Rag::SectionNeighborExpander.method(:invalidate!)
    definition = Rag::CompanionDefinitionSource.method(:invalidate!)
    Rag::SectionNeighborExpander.define_singleton_method(:invalidate!) { |prefix| seen << prefix }
    Rag::CompanionDefinitionSource.define_singleton_method(:invalidate!) { |prefix| seen << prefix }
    service.resume!
  ensure
    Rag::SectionNeighborExpander.define_singleton_method(:invalidate!, expander) if expander
    Rag::CompanionDefinitionSource.define_singleton_method(:invalidate!, definition) if definition
  end

  def service
    PUB.new(
      remote: @remote,
      agent: @agent,
      kb_sync: FakeSync.new,
      source_body: @body,
      source_sidecar: @sidecar,
      backup_dir: @dir.join("restore"),
      evidence_dir: @dir,
      sleep_for: ->(_seconds) { },
      poll_limit: 2
    )
  end

  def publish_fragments!
    parts = Wiring905Page5ChunkSplit.call(body: @body, sidecar: @sidecar)
    parts.each do |part|
      @remote.upload_binary("#{PREFIX}#{part['filename']}", part["body"], TEXT)
      @remote.upload_binary("#{PREFIX}#{part['filename']}.metadata.json", part["sidecar"], TEXT)
    end
    @remote.puts.clear
    inventory = @remote.list_object_summaries!(prefix: PREFIX)
    File.write(@dir.join("report.json"), JSON.generate(
      "prefix_count_after" => inventory.size,
      "stopped" => { "stage" => "sync_start", "message" => "aurora" }
    ))
    FileUtils.mkdir_p(@dir.join("restore/objects"))
    body_key = "#{PREFIX}chunk_p5_1.txt"
    sidecar_key = "#{PREFIX}chunk_p5_1.txt.metadata.json"
    FileUtils.mkdir_p(@dir.join("restore/objects", PREFIX))
    File.binwrite(@dir.join("restore/objects", body_key), @body)
    File.binwrite(@dir.join("restore/objects", sidecar_key), @sidecar)
    File.write(@dir.join("restore/manifest.json"), JSON.generate(
      "objects" => [
        { "key" => body_key, "sha256" => PUB::SOURCE_SHA256, "content_type" => TEXT, "metadata" => {} },
        { "key" => sidecar_key, "sha256" => PUB::SIDECAR_SHA256, "content_type" => TEXT, "metadata" => {} }
      ],
      "absent" => PUB::CREATED_NAMES.map { |name| "#{PREFIX}#{name}" }
    ))
  end

  def publish
    seen = @invalidated
    expander = Rag::SectionNeighborExpander.method(:invalidate!)
    definition = Rag::CompanionDefinitionSource.method(:invalidate!)
    Rag::SectionNeighborExpander.define_singleton_method(:invalidate!) { |prefix| seen << prefix }
    Rag::CompanionDefinitionSource.define_singleton_method(:invalidate!) { |prefix| seen << prefix }
    PUB.new(
      remote: @remote,
      agent: @agent,
      kb_sync: FakeSync.new,
      source_body: @body,
      source_sidecar: @sidecar,
      backup_dir: @dir.join("restore"),
      evidence_dir: @dir,
      sleep_for: ->(_seconds) { },
      poll_limit: 2
    ).call
  ensure
    Rag::SectionNeighborExpander.define_singleton_method(:invalidate!, expander) if expander
    Rag::CompanionDefinitionSource.define_singleton_method(:invalidate!, definition) if definition
  end

  def remote_objects
    {
      "#{PREFIX}chunk_p5_1.txt" => object(@body),
      "#{PREFIX}chunk_p5_1.txt.metadata.json" => object(@sidecar),
      "#{PREFIX}chunk_p4_1.txt" => object("other")
    }
  end

  def object(body)
    { body: body, content_type: TEXT, metadata: {}, content_encoding: nil }
  end
end
