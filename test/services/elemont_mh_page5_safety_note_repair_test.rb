# frozen_string_literal: true

require "test_helper"
require "open3"

class ElemontMhPage5SafetyNoteRepairTest < ActiveSupport::TestCase
  PATCH = ElemontMhPage5SafetyNotePatch
  SCRIPT = Rails.root.join("script/patch_elemont_chunk_p5_1_safety_note.rb")
  BEFORE_PATH = Rails.root.join("test/fixtures/files/field_companion/phase1_20261010T153620Z/bodies/b0003.txt")
  AFTER_PATH = Rails.root.join("test/fixtures/files/elemont/page5_safety_note/chunk_p5_1_after.txt")
  SIDECAR = "{\"document_id\":\"121bfffe0827f6bc681ba9bdc91050390055\"}\n".b

  setup do
    @dir = Pathname(Dir.mktmpdir("page5-repair"))
    @before = BEFORE_PATH.binread
    @after = AFTER_PATH.binread
    @adapter = ActiveJob::Base.queue_adapter
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir&.exist?
  end

  test "uploads only the text key and starts one ingestion on the exact data source" do
    store = memory
    agent = agent(ids: [ "OTHER", PATCH::DATA_SOURCE_ID ])
    sleeps = 0

    patched = repair(store, agent, sleep_for: lambda { |_|
      sleeps += 1
    }).call

    assert_equal @after.b, patched.b
    assert_equal [ PATCH::KEY ], store.uploads.map(&:first)
    assert_equal @after.b, store.objects[PATCH::KEY].b
    assert_equal SIDECAR, store.objects[PATCH::SIDECAR_KEY]
    assert_equal [ { knowledge_base_id: PATCH::KNOWLEDGE_BASE_ID, data_source_id: PATCH::DATA_SOURCE_ID } ], agent.starts
    assert_equal PATCH::DATA_SOURCE_ID, agent.gets.first[:data_source_id]
    assert_equal 0, sleeps
    assert_equal @adapter, ActiveJob::Base.queue_adapter
    assert_equal @before.b, @dir.join("chunk_p5_1_before.bin").binread
    assert_equal SIDECAR, @dir.join("chunk_p5_1.metadata.json.before").binread
    assert_equal PATCH.digest(@before), manifest[/live_sha256=(\h+)/, 1]
    assert_equal PATCH.digest(SIDECAR), manifest[/sidecar_sha256=(\h+)/, 1]
  end

  test "records the downloaded sha when the live body has a trailing newline" do
    source = @before + "\n".b
    store = memory(source)
    listed = agent

    patched = repair(store, listed, sleep_for: ->(_) { flunk("slept") }).call

    assert_equal @after.b + "\n".b, patched.b
    assert_equal "b466665b37f76cf2e35441787bbd30b3fe2dd42d623b4de359e05814e2c8a85a", PATCH.digest(patched)
    assert_equal "7658478b42b0f4bc8e7ae603a069c11d42e78d69181d143dbf08e9709b637380", manifest[/live_sha256=(\h+)/, 1]
    assert_not_equal "8baae756dab099e124b046057bfb4f6e835d85a5b2922f2eff1e64a637efd09c", manifest[/live_sha256=(\h+)/, 1]
    assert_equal source, @dir.join("chunk_p5_1_before.bin").binread
  end

  test "uses the requested data source when it is on a later page" do
    pages = {
      nil => { ids: [ "OTHER" ], next: "p2" },
      "p2" => { ids: [ PATCH::DATA_SOURCE_ID ], next: nil }
    }
    store = memory
    agent = agent(pages: pages)

    repair(store, agent, sleep_for: ->(_) { flunk("slept") }).call

    assert_equal [ nil, "p2" ], agent.lists.pluck(:next_token)
    assert_equal PATCH::DATA_SOURCE_ID, agent.starts.first[:data_source_id]
  end

  test "stops before any download when confirmation, bucket, kb or data source do not match" do
    [
      repair(memory, agent, confirm: nil),
      repair(memory, agent, confirm: "true"),
      repair(memory, agent, bucket: "smart-deal-dev-kb"),
      repair(memory(bucket_name: "smart-deal-dev-kb"), agent),
      repair(memory, agent, knowledge_base_id: "QGVYLPTEGT"),
      repair(memory, agent, data_source_id: "8DUTRUCDTS")
    ].each do |run|
      store = run.instance_variable_get(:@s3)
      listed = run.instance_variable_get(:@agent)
      assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { run.call }
      assert_empty store.downloads
      assert_empty store.uploads
      assert_empty listed.lists
    end
  end

  test "stops when the exact data source is absent and does not fall back" do
    store = memory
    agent = agent(ids: [ "OTHER" ])

    error = assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) do
      repair(store, agent).call
    end

    assert_match(/PJ0N58DMHG/, error.message)
    assert_empty store.downloads
    assert_empty store.uploads
    assert_empty agent.starts
  end

  test "stops when the data source list does not finish" do
    store = memory
    agent = agent(always_next: true)

    assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(store, agent).call }

    assert_equal 10, agent.lists.size
    assert_empty store.downloads
    assert_empty store.uploads
  end

  test "stops when the chunk or the sidecar is missing" do
    missing_chunk = memory
    missing_chunk.objects.delete(PATCH::KEY)
    missing_sidecar = memory
    missing_sidecar.objects.delete(PATCH::SIDECAR_KEY)

    [ missing_chunk, missing_sidecar ].each do |store|
      listed = agent
      assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(store, listed).call }
      assert_empty store.uploads
      assert_empty listed.starts
      assert_not @dir.join("chunk_p5_1_before.bin").exist?
    end
  end

  test "backs up and stops when the live bytes are not the approved text" do
    invalid = memory("no es la pagina".b)
    agent_for_invalid = agent
    assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(invalid, agent_for_invalid).call }
    assert_empty invalid.uploads
    assert_empty agent_for_invalid.starts
    assert_equal "no es la pagina".b, @dir.join("chunk_p5_1_before.bin").binread

    broken = memory("\xff".b)
    assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(broken, agent).call }
    assert_empty broken.uploads
    assert_equal "\xff".b, @dir.join("chunk_p5_1_before.bin").binread

    already = memory(@after)
    agent_for_already = agent
    assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(already, agent_for_already).call }
    assert_empty already.uploads
    assert_empty agent_for_already.starts
    assert_equal @after.b, @dir.join("chunk_p5_1_before.bin").binread
  end

  test "restores the body and skips ingestion when the sidecar changes" do
    store = memory
    store.sidecar_mutates = true
    listed = agent

    error = assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(store, listed).call }

    assert_match(/sidecar was not written/, error.message)
    assert_equal [ PATCH::KEY, PATCH::KEY ], store.uploads.map(&:first)
    assert_equal @before.b, store.uploads.last.last.b
    assert_equal @before.b, store.objects[PATCH::KEY].b
    assert_equal SIDECAR, store.objects[PATCH::SIDECAR_KEY]
    assert_empty listed.starts
  end

  test "restores the body and skips ingestion when the text roundtrip differs" do
    store = memory
    store.text_lies = true
    listed = agent

    assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(store, listed).call }

    assert_equal @before.b, store.objects[PATCH::KEY].b
    assert_empty listed.starts
  end

  test "restores the body and starts one rollback ingestion when the job fails" do
    store = memory
    listed = agent(statuses: [ "FAILED" ])

    error = assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(store, listed).call }

    assert_match(/rollback job job-2/, error.message)
    assert_equal @before.b, store.objects[PATCH::KEY].b
    assert_equal [ PATCH::DATA_SOURCE_ID, PATCH::DATA_SOURCE_ID ], listed.starts.pluck(:data_source_id)
    assert_equal 1, listed.gets.size
  end

  test "rolls back a complete job that did not modify a document" do
    store = memory
    listed = agent(modified: 0)

    assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(store, listed).call }

    assert_equal @before.b, store.objects[PATCH::KEY].b
    assert_equal 2, listed.starts.size
  end

  test "rolls back a complete job that reports a failed document" do
    store = memory
    listed = agent(failed: 1)

    assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(store, listed).call }

    assert_equal 2, listed.starts.size
    assert_equal @before.b, store.objects[PATCH::KEY].b
  end

  test "keeps the backup and does not start a second job while ingestion is still running" do
    store = memory
    listed = agent(statuses: [ "IN_PROGRESS" ])
    sleeps = 0

    error = assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) do
      repair(store, listed, sleep_for: lambda { |_|
        sleeps += 1
      }).call
    end

    assert_match(/no second job started/, error.message)
    assert_match(@dir.to_s, error.message)
    assert_equal ElemontMhPage5SafetyNoteRepair::POLL_LIMIT - 1, sleeps
    assert_equal 1, listed.starts.size
    assert_equal @after.b, store.objects[PATCH::KEY].b
    assert_equal @before.b, @dir.join("chunk_p5_1_before.bin").binread
  end

  test "waits through STARTING and then accepts COMPLETE" do
    store = memory
    listed = agent(statuses: [ "STARTING", "COMPLETE" ])
    sleeps = 0

    repair(store, listed, sleep_for: lambda { |_|
      sleeps += 1
    }).call

    assert_equal 1, sleeps
    assert_equal 1, listed.starts.size
    assert_equal @after.b, store.objects[PATCH::KEY].b
  end

  test "does not open a rollback ingestion when the restore upload fails" do
    store = memory
    store.fail_second_upload = true
    listed = agent(statuses: [ "FAILED" ])

    error = assert_raises(ElemontMhPage5SafetyNoteRepair::Stop) { repair(store, listed).call }

    assert_match(/rollback upload failed/, error.message)
    assert_equal 1, listed.starts.size
    assert_equal @before.b, @dir.join("chunk_p5_1_before.bin").binread
  end

  test "the script aborts before constructing a client" do
    source = SCRIPT.read
    assert source.index("abort(") < source.index('require "aws-sdk-bedrockagent"')
    assert_no_match(/queue_adapter\s*=/, source)
    assert_not_includes source, "KbSyncService"
    assert_not_includes source, "BulkKbSyncService"
    assert_not_includes source, "8baae756dab099e124b046057bfb4f6e835d85a5b2922f2eff1e64a637efd09c"
    assert_no_match(/queue_adapter\s*=/, Rails.root.join("app/services/elemont_mh_page5_safety_note_repair.rb").read)

    _stdout, stderr, status = Open3.capture3(
      { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME") },
      RbConfig.ruby,
      SCRIPT.to_s
    )

    assert_equal 1, status.exitstatus
    assert_includes stderr, "RAG_PAGE5_SAFETY_NOTE_CONFIRM=1"
  end

  private

  def memory(body = @before, bucket_name: PATCH::BUCKET)
    Memory.new(
      { PATCH::KEY => body, PATCH::SIDECAR_KEY => SIDECAR.dup },
      bucket_name: bucket_name
    )
  end

  def agent(**)
    Agent.new(**)
  end

  def repair(store, listed, confirm: "1", bucket: PATCH::BUCKET, knowledge_base_id: PATCH::KNOWLEDGE_BASE_ID,
             data_source_id: PATCH::DATA_SOURCE_ID, sleep_for: ->(_) { flunk("slept") })
    ElemontMhPage5SafetyNoteRepair.new(
      s3: store,
      agent: listed,
      bucket: bucket,
      knowledge_base_id: knowledge_base_id,
      data_source_id: data_source_id,
      backup_dir: @dir,
      confirm: confirm,
      sleep_for: sleep_for
    )
  end

  def manifest
    @dir.join("manifest.txt").read
  end

  class Memory
    attr_reader :downloads, :uploads, :objects
    attr_accessor :bucket_name, :sidecar_mutates, :text_lies, :fail_second_upload

    def initialize(objects, bucket_name:)
      @objects = objects
      @bucket_name = bucket_name
      @downloads = []
      @uploads = []
    end

    def download(key)
      @downloads << key
      return "mutated-sidecar".b if sidecar_mutates && key.end_with?(".metadata.json") && @uploads.any?
      return "lied-text".b if text_lies && key.end_with?(".txt") && @uploads.any? { |entry| entry[0] == key }

      @objects[key]&.dup
    end

    def upload_text(key, content)
      @uploads << [ key, content.dup ]
      return nil if fail_second_upload && @uploads.size > 1

      @objects[key] = content.dup
      key
    end
  end

  class Agent
    Summary = Struct.new(:data_source_id)
    List = Struct.new(:data_source_summaries, :next_token)
    Stats = Struct.new(:number_of_documents_failed, :number_of_modified_documents_indexed)
    Job = Struct.new(:ingestion_job_id, :status, :statistics)
    Wrap = Struct.new(:ingestion_job)

    attr_reader :lists, :starts, :gets

    def initialize(ids: [ PATCH::DATA_SOURCE_ID ], statuses: [ "COMPLETE" ], failed: 0, modified: 1,
                   pages: nil, always_next: false)
      @ids = ids
      @statuses = statuses
      @failed = failed
      @modified = modified
      @pages = pages
      @always_next = always_next
      @lists = []
      @starts = []
      @gets = []
    end

    def list_data_sources(knowledge_base_id:, next_token: nil)
      @lists << { knowledge_base_id: knowledge_base_id, next_token: next_token }
      return List.new([ Summary.new("OTHER") ], "t#{@lists.size}") if @always_next

      if @pages
        page = @pages.fetch(next_token)
        return List.new(page[:ids].map { |id| Summary.new(id) }, page[:next])
      end

      List.new(@ids.map { |id| Summary.new(id) }, nil)
    end

    def start_ingestion_job(knowledge_base_id:, data_source_id:)
      @starts << { knowledge_base_id: knowledge_base_id, data_source_id: data_source_id }
      Wrap.new(Job.new("job-#{@starts.size}", nil, nil))
    end

    def get_ingestion_job(knowledge_base_id:, data_source_id:, ingestion_job_id:)
      @gets << {
        knowledge_base_id: knowledge_base_id,
        data_source_id: data_source_id,
        ingestion_job_id: ingestion_job_id
      }
      status = @statuses[@gets.size - 1] || @statuses.last
      Wrap.new(Job.new(ingestion_job_id, status, Stats.new(@failed, @modified)))
    end
  end
end
