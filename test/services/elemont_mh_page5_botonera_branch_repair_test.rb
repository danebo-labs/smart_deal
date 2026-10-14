# frozen_string_literal: true

require "test_helper"
require "open3"

class ElemontMhPage5BotoneraBranchRepairTest < ActiveSupport::TestCase
  REPAIR = ElemontMhPage5BotoneraBranchRepair
  PATCH = ElemontMhPage5BotoneraBranchPatch
  SCRIPT = Rails.root.join("script/patch_elemont_chunk_p5_1_botonera_branch.rb")
  BASE_PATH = Rails.root.join("test/fixtures/files/elemont/page5_safety_note/chunk_p5_1_after.txt")
  CANDIDATE_PATH = Rails.root.join("test/fixtures/files/elemont/page5_botonera_branch/chunk_p5_1_candidate.txt")
  PRESENCE_PATH = Rails.root.join("test/fixtures/files/field_companion/phase1_20261010T153620Z/bodies/b0003.txt")
  SIDECAR = "{\"document_id\":\"121bfffe0827f6bc681ba9bdc91050390055\"}\n".b
  FOREIGN_KEY = "bulk_chunks/3/5b1859a0bfe1c5b11e58214555f8c2fe93e6/chunk_p5_1.txt"
  OTHER_KEY = "bulk_chunks/9/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/chunk_p2_1.txt"

  setup do
    @dir = Pathname(Dir.mktmpdir("page5-botonera-repair"))
    @base = BASE_PATH.binread
    @candidate = CANDIDATE_PATH.binread
    @adapter = ActiveJob::Base.queue_adapter
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir&.exist?
  end

  test "locks the same object and the approved base and candidate" do
    assert_equal ElemontMhPage5SafetyNotePatch::KEY, REPAIR::KEY
    assert_equal "#{REPAIR::KEY}.metadata.json", REPAIR::SIDECAR_KEY
    assert_equal "multimodal-source-destination", REPAIR::BUCKET
    assert_equal "Y7RZWMFJSR", REPAIR::KNOWLEDGE_BASE_ID
    assert_equal "PJ0N58DMHG", REPAIR::DATA_SOURCE_ID
    assert_equal "us-east-1", REPAIR::REGION
    assert_equal "RAG_PAGE5_BOTONERA_BRANCH_CONFIRM", REPAIR::CONFIRM_ENV
    assert_not_equal "RAG_PAGE5_SAFETY_NOTE_CONFIRM", REPAIR::CONFIRM_ENV
    assert_equal PATCH::BASE_SHA, REPAIR::BASE_SHA
    assert_equal REPAIR::BASE_SHA, PATCH.digest(@base)
    assert_equal REPAIR::CANDIDATE_SHA, PATCH.digest(@candidate)
    assert_equal 7359, @base.bytesize
    assert_equal 9193, @candidate.bytesize
  end

  test "uploads only the text key and starts one ingestion on the exact data source" do
    store = memory
    agent = agent(ids: [ "OTHER", REPAIR::DATA_SOURCE_ID ])
    sleeps = 0
    run = repair(store, agent, sleep_for: lambda { |_|
      sleeps += 1
    })

    patched = run.call

    assert_equal @candidate.b, patched.b
    assert_equal [ REPAIR::KEY ], store.uploads.map(&:first)
    assert_equal @candidate.b, store.objects[REPAIR::KEY].b
    assert_equal SIDECAR, store.objects[REPAIR::SIDECAR_KEY]
    assert_equal [ { knowledge_base_id: REPAIR::KNOWLEDGE_BASE_ID, data_source_id: REPAIR::DATA_SOURCE_ID } ], agent.starts
    assert_equal REPAIR::DATA_SOURCE_ID, agent.gets.first[:data_source_id]
    assert_equal 0, sleeps
    assert_equal @adapter, ActiveJob::Base.queue_adapter
    assert_empty run.foreign_failures
    assert_equal @base.b, @dir.join("chunk_p5_1_before.bin").binread
    assert_equal SIDECAR, @dir.join("chunk_p5_1.metadata.json.before").binread
    assert_equal REPAIR::BASE_SHA, manifest[/live_sha256=(\h+)/, 1]
    assert_equal PATCH.digest(SIDECAR), manifest[/sidecar_sha256=(\h+)/, 1]
    assert_equal REPAIR::BASE_SHA, manifest[/expected_base_sha256=(\h+)/, 1]
    assert_equal REPAIR::CANDIDATE_SHA, manifest[/expected_candidate_sha256=(\h+)/, 1]
    assert_equal REPAIR::CANDIDATE_SHA, manifest[/patched_sha256=(\h+)/, 1]
    assert_includes manifest, "bucket=#{REPAIR::BUCKET}"
    assert_includes manifest, "knowledge_base_id=#{REPAIR::KNOWLEDGE_BASE_ID}"
    assert_includes manifest, "data_source_id=#{REPAIR::DATA_SOURCE_ID}"
    assert_includes manifest, "region=#{REPAIR::REGION}"
    assert_includes manifest, "job_id=job-1 role=initial"
    assert_includes manifest, "failure_attribution=clean"
    assert_includes manifest, "documents_failed=0"
    assert_includes manifest, "documents_modified=1"
    assert_not_includes manifest, "role=rollback"
    assert_not_includes manifest, "aws_error="
    assert_not_includes manifest, "failure_attribution=foreign"
  end

  test "records the downloaded sha when the live body has a trailing newline" do
    source = @base + "\n".b
    store = memory(source)
    run = repair(store, agent)

    patched = run.call

    assert_equal @candidate.b + "\n".b, patched.b
    assert_equal "bc6d057d6ed34adae196692c7a48e1291ac020b08150027c51e13a398b77441e", PATCH.digest(patched)
    assert_equal "bc6d057d6ed34adae196692c7a48e1291ac020b08150027c51e13a398b77441e", manifest[/patched_sha256=(\h+)/, 1]
    assert_equal "b466665b37f76cf2e35441787bbd30b3fe2dd42d623b4de359e05814e2c8a85a", manifest[/live_sha256=(\h+)/, 1]
    assert_equal REPAIR::CANDIDATE_SHA, manifest[/expected_candidate_sha256=(\h+)/, 1]
    assert_equal source, @dir.join("chunk_p5_1_before.bin").binread
    assert_empty run.foreign_failures
  end

  test "uses the requested data source when it is on a later page" do
    pages = {
      nil => { ids: [ "OTHER" ], next: "p2" },
      "p2" => { ids: [ REPAIR::DATA_SOURCE_ID ], next: nil }
    }
    store = memory
    listed = agent(pages: pages)

    repair(store, listed).call

    assert_equal [ nil, "p2" ], listed.lists.pluck(:next_token)
    assert_equal REPAIR::DATA_SOURCE_ID, listed.starts.first[:data_source_id]
  end

  test "stops before any download when confirmation, bucket, kb, data source or region do not match" do
    [
      repair(memory, agent, confirm: nil),
      repair(memory, agent, confirm: "true"),
      repair(memory, agent, confirm: "RAG_PAGE5_SAFETY_NOTE_CONFIRM"),
      repair(memory, agent, bucket: "smart-deal-dev-kb"),
      repair(memory(bucket_name: "smart-deal-dev-kb"), agent),
      repair(memory, agent, knowledge_base_id: "QGVYLPTEGT"),
      repair(memory, agent, data_source_id: "8DUTRUCDTS"),
      repair(memory, agent, region: "eu-west-1")
    ].each do |run|
      store = run.instance_variable_get(:@s3)
      listed = run.instance_variable_get(:@agent)
      assert_raises(REPAIR::Stop) { run.call }
      assert_empty store.downloads
      assert_empty store.uploads
      assert_empty listed.lists
    end
  end

  test "stops when the exact data source is absent and does not fall back" do
    store = memory
    listed = agent(ids: [ "OTHER" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_match(/PJ0N58DMHG/, error.message)
    assert_empty store.downloads
    assert_empty store.uploads
    assert_empty listed.starts
  end

  test "stops when the data source list does not finish" do
    store = memory
    listed = agent(always_next: true)

    assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_equal 10, listed.lists.size
    assert_empty store.downloads
    assert_empty store.uploads
  end

  test "stops when the chunk or the sidecar is missing" do
    missing_chunk = memory
    missing_chunk.objects.delete(REPAIR::KEY)
    missing_sidecar = memory
    missing_sidecar.objects.delete(REPAIR::SIDECAR_KEY)

    [ missing_chunk, missing_sidecar ].each do |store|
      listed = agent
      assert_raises(REPAIR::Stop) { repair(store, listed).call }
      assert_empty store.uploads
      assert_empty listed.starts
      assert_not @dir.join("chunk_p5_1_before.bin").exist?
    end
  end

  test "backs up and stops when the live bytes are not the approved base" do
    invalid = memory("no es la pagina".b)
    listed = agent
    assert_raises(REPAIR::Stop) { repair(invalid, listed).call }
    assert_empty invalid.uploads
    assert_empty listed.starts
    assert_equal "no es la pagina".b, @dir.join("chunk_p5_1_before.bin").binread

    broken = memory("\xff".b)
    assert_raises(REPAIR::Stop) { repair(broken, agent).call }
    assert_empty broken.uploads
    assert_equal "\xff".b, @dir.join("chunk_p5_1_before.bin").binread

    already = memory(@candidate)
    listed_again = agent
    error = assert_raises(REPAIR::Stop) { repair(already, listed_again).call }
    assert_match(/expected base #{REPAIR::BASE_SHA}/, error.message)
    assert_empty already.uploads
    assert_empty listed_again.starts
    assert_equal @candidate.b, @dir.join("chunk_p5_1_before.bin").binread

    presafety = memory(PRESENCE_PATH.binread)
    assert_raises(REPAIR::Stop) { repair(presafety, agent).call }
    assert_empty presafety.uploads

    doubled = memory(@base + "\n\n".b)
    assert_raises(REPAIR::Stop) { repair(doubled, agent).call }
    assert_empty doubled.uploads
  end

  test "restores the body and skips ingestion when the sidecar changes" do
    store = memory
    store.sidecar_mutates = true
    listed = agent

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_match(/sidecar was not written/, error.message)
    assert_equal [ REPAIR::KEY, REPAIR::KEY ], store.uploads.map(&:first)
    assert_equal @base.b, store.uploads.last.last.b
    assert_equal @base.b, store.objects[REPAIR::KEY].b
    assert_equal SIDECAR, store.objects[REPAIR::SIDECAR_KEY]
    assert_empty listed.starts
    assert_not_includes manifest, "role="
  end

  test "restores the body and skips ingestion when the text roundtrip differs" do
    store = memory
    store.text_lies = true
    listed = agent

    assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_equal @base.b, store.objects[REPAIR::KEY].b
    assert_empty listed.starts
  end

  test "keeps the new body when the only failed document is another chunk" do
    reason = "Input token count 9048 exceeds 8192 for #{FOREIGN_KEY}"
    store = memory
    listed = agent(failed: 1, failure_reasons: [ reason ])
    run = repair(store, listed)

    patched = run.call

    assert_equal @candidate.b, patched.b
    assert_equal @candidate.b, store.objects[REPAIR::KEY].b
    assert_equal [ reason ], run.foreign_failures
    assert_equal 1, listed.starts.size
    assert_equal [ { job_id: "job-1", data_source_id: REPAIR::DATA_SOURCE_ID, role: "initial" } ], run.ingestions
    assert_includes manifest, "failure_attribution=foreign"
    assert_includes manifest, "failure_reason=#{reason}"
    assert_includes manifest, "stage=foreign_failures_accepted"
    assert_not_includes manifest, "role=rollback"
    assert manifest.index("failure_attribution=foreign") < manifest.index("stage=foreign_failures_accepted")
  end

  test "keeps the new body when a different document key is the only failure" do
    reason = "failed document #{OTHER_KEY}"
    store = memory
    listed = agent(failed: 1, failure_reasons: [ reason ])
    run = repair(store, listed)

    run.call

    assert_equal [ reason ], run.foreign_failures
    assert_equal @candidate.b, store.objects[REPAIR::KEY].b
    assert_equal 1, listed.starts.size
  end

  test "rolls back when a failure reason names the target key" do
    reason = "could not index s3://#{REPAIR::BUCKET}/#{REPAIR::KEY}"
    store = memory
    listed = agent(failed: 1, failure_reasons: [ reason, "also #{FOREIGN_KEY}" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_match(/target document failed/, error.message)
    assert_match(/rollback job job-2/, error.message)
    assert_equal @base.b, store.objects[REPAIR::KEY].b
    assert_equal [ REPAIR::DATA_SOURCE_ID, REPAIR::DATA_SOURCE_ID ], listed.starts.pluck(:data_source_id)
    assert_equal 1, listed.gets.size
    assert manifest.index("failure_attribution=target") < manifest.index("job_id=job-2 role=rollback")
    assert_includes manifest, "stage=body_restored"
  end

  test "rolls back a failed job when the reason names the target key" do
    store = memory
    listed = agent(statuses: [ "FAILED" ], failure_reasons: [ "could not index #{REPAIR::KEY}" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_match(/target document failed/, error.message)
    assert_equal @base.b, store.objects[REPAIR::KEY].b
    assert_equal 2, listed.starts.size
    assert_not_includes manifest, "failure_attribution=unattributed"
  end

  test "rolls back when the target key appears in a different case" do
    store = memory
    listed = agent(failed: 1, failure_reasons: [ "error #{REPAIR::KEY.upcase}" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_match(/target document failed/, error.message)
    assert_equal @base.b, store.objects[REPAIR::KEY].b
    assert_equal 2, listed.starts.size
  end

  test "does not roll back a failed job that does not name the target" do
    store = memory
    listed = agent(statuses: [ "FAILED" ], failed: 1, failure_reasons: [ "token limit #{FOREIGN_KEY}" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_uncertain_outcome(error, store)
    assert_includes manifest, "failure_attribution=unattributed"
    assert_includes manifest, "stage=outcome_uncertain"
    assert_not_includes manifest, "role=rollback"
  end

  test "does not roll back a failed job that gives no document key" do
    store = memory
    listed = agent(statuses: [ "FAILED" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_uncertain_outcome(error, store)
    assert_not_includes manifest, "role=rollback"
  end

  test "does not treat the shared filename as evidence of the target" do
    store = memory
    listed = agent(failed: 1, failure_reasons: [ "chunk_p5_1.txt exceeded the token limit" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_uncertain_outcome(error, store)
    assert_includes manifest, "failure_attribution=unattributed"
    assert_not_includes manifest, "role=rollback"
  end

  test "does not roll back when a failed count has fewer named documents than failures" do
    store = memory
    listed = agent(failed: 2, failure_reasons: [ "failed #{FOREIGN_KEY}" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_uncertain_outcome(error, store)
    assert_includes manifest, "documents_failed=2"
    assert_not_includes manifest, "role=rollback"
  end

  test "does not roll back when one failure reason names no document" do
    store = memory
    listed = agent(failed: 1, failure_reasons: [ "failed #{OTHER_KEY}", "token limit exceeded" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_uncertain_outcome(error, store)
    assert_not_includes manifest, "role=rollback"
  end

  test "does not roll back when statistics are missing" do
    store = memory
    listed = agent(statistics: nil, failed: nil)

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_uncertain_outcome(error, store)
    assert_includes manifest, "documents_failed=missing"
    assert_includes manifest, "documents_modified=missing"
  end

  test "rolls back a complete job that did not modify a document" do
    store = memory
    listed = agent(modified: 0)

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_match(/target document was not modified/, error.message)
    assert_match(/rollback job job-2/, error.message)
    assert_equal @base.b, store.objects[REPAIR::KEY].b
    assert_equal 2, listed.starts.size
    assert_includes manifest, "failure_attribution=unmodified"
  end

  test "does not roll back a complete job that modified nothing while another document failed" do
    store = memory
    listed = agent(modified: 0, failed: 1, failure_reasons: [ "failed #{FOREIGN_KEY}" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_uncertain_outcome(error, store)
    assert_not_includes manifest, "role=rollback"
  end

  test "keeps the backup and does not start a second job while ingestion is still running" do
    store = memory
    listed = agent(statuses: [ "IN_PROGRESS" ])
    sleeps = 0

    error = assert_raises(REPAIR::Stop) do
      repair(store, listed, sleep_for: lambda { |_|
        sleeps += 1
      }).call
    end

    assert_match(/no second job started/, error.message)
    assert_match(@dir.to_s, error.message)
    assert_equal REPAIR::POLL_LIMIT - 1, sleeps
    assert_equal 1, listed.starts.size
    assert_equal @candidate.b, store.objects[REPAIR::KEY].b
    assert_equal @base.b, @dir.join("chunk_p5_1_before.bin").binread
    assert_not_includes manifest, "role=rollback"
    assert_not_includes manifest, "failure_attribution="
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
    assert_equal @candidate.b, store.objects[REPAIR::KEY].b
  end

  test "stops without another write when the upload raises" do
    store = memory
    store.raise_on_upload = true
    listed = agent
    run = repair(store, listed)

    error = assert_raises(REPAIR::Stop) { run.call }

    assert_match(/aws error after write/, error.message)
    assert_includes error.message, "confirmed_stage=patched"
    assert_includes error.message, "job_id=not_received"
    assert_includes error.message, "backup=#{@dir}"
    assert_no_match(/restor/i, error.message)
    assert_equal 1, store.uploads.size
    assert_equal @base.b, store.objects[REPAIR::KEY].b
    assert_empty listed.starts
    assert_empty run.ingestions
    assert_includes manifest, "aws_error=RuntimeError: upload failed"
    assert_includes manifest, "expected_candidate_sha256=#{REPAIR::CANDIDATE_SHA}"
  end

  test "stops without another write when the upload result is blank" do
    store = memory
    store.fail_first_upload = true
    listed = agent

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_match(/aws error after write/, error.message)
    assert_includes error.message, "text upload failed"
    assert_includes error.message, "job_id=not_received"
    assert_equal 1, store.uploads.size
    assert_empty listed.starts
    assert_equal @base.b, store.objects[REPAIR::KEY].b
  end

  test "stops without another write when starting the ingestion raises" do
    store = memory
    listed = agent(start_error: RuntimeError.new("start failed"))
    run = repair(store, listed)

    error = assert_raises(REPAIR::Stop) { run.call }

    assert_uncertain_after_write(error, store)
    assert_includes error.message, "confirmed_stage=publish_checked"
    assert_includes error.message, "job_id=not_received"
    assert_includes manifest, "patched_sha256=#{REPAIR::CANDIDATE_SHA}"
    assert_includes manifest, "confirmed_stage=publish_checked"
    assert_includes manifest, "backup_dir=#{@dir}"
    assert_includes manifest, "aws_error=RuntimeError: start failed"
    assert_not_includes manifest, "role="
    assert_equal 1, listed.starts.size
    assert_empty listed.gets
    assert_empty run.ingestions
  end

  test "stops without another write when the ingestion start returns no job id" do
    store = memory
    listed = agent(blank_job_id: true)
    run = repair(store, listed)

    error = assert_raises(REPAIR::Stop) { run.call }

    assert_uncertain_after_write(error, store)
    assert_includes error.message, "job_id=not_received"
    assert_not_includes manifest, "role="
    assert_equal 1, listed.starts.size
    assert_empty run.ingestions
  end

  test "stops during polling and keeps the job id already written" do
    store = memory
    listed = agent(get_error: RuntimeError.new("poll failed"), manifest_path: @dir.join("manifest.txt"))
    run = repair(store, listed)

    error = assert_raises(REPAIR::Stop) { run.call }

    assert_uncertain_after_write(error, store)
    assert_includes error.message, "job_id=job-1"
    assert_includes listed.manifest_at_get, "job_id=job-1 role=initial"
    assert_includes manifest, "job_id=job-1 role=initial"
    assert_includes manifest, "confirmed_stage=ingestion_started"
    assert_includes manifest, "backup_dir=#{@dir}"
    assert_includes manifest, "aws_error=RuntimeError: poll failed"
    assert_equal 1, listed.starts.size
    assert_equal 1, listed.gets.size
    assert_equal [ { job_id: "job-1", data_source_id: REPAIR::DATA_SOURCE_ID, role: "initial" } ], run.ingestions
  end

  test "stops a later poll error without continuing or rolling back" do
    store = memory
    listed = agent(
      statuses: [ "STARTING" ],
      get_error: RuntimeError.new("poll failed"),
      get_error_after: 1,
      manifest_path: @dir.join("manifest.txt")
    )
    sleeps = 0

    error = assert_raises(REPAIR::Stop) do
      repair(store, listed, sleep_for: lambda { |_|
        sleeps += 1
      }).call
    end

    assert_uncertain_after_write(error, store)
    assert_equal 1, sleeps
    assert_equal 1, listed.starts.size
    assert_equal 2, listed.gets.size
    assert_includes listed.manifest_at_get, "job_id=job-1 role=initial"
    assert_includes manifest, "status=STARTING"
    assert_not_includes manifest, "role=rollback"
  end

  test "does not roll back when the ingestion status is missing" do
    store = memory
    listed = agent(statuses: [ nil ])
    run = repair(store, listed)

    error = assert_raises(REPAIR::Stop) { run.call }

    assert_uncertain_after_write(error, store)
    assert_includes error.message, "job_id=job-1"
    assert_includes manifest, "job_id=job-1 role=initial"
    assert_not_includes manifest, "role=rollback"
    assert_equal 1, listed.gets.size
    assert_equal 1, run.ingestions.size
  end

  test "does not roll back when the ingestion status is unrecognized" do
    store = memory
    listed = agent(statuses: [ "STOPPED" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_uncertain_after_write(error, store)
    assert_includes error.message, "unrecognized"
    assert_not_includes manifest, "role=rollback"
  end

  test "does not restore when a read after the write raises" do
    store = memory
    store.raise_after_upload = true
    listed = agent

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_uncertain_after_write(error, store)
    assert_includes error.message, "confirmed_stage=text_uploaded"
    assert_includes error.message, "job_id=not_received"
    assert_includes manifest, "aws_error=RuntimeError: read failed"
    assert_empty listed.starts
  end

  test "does not start a second rollback when that ingestion start raises" do
    store = memory
    listed = agent(
      failed: 1,
      failure_reasons: [ "could not index #{REPAIR::KEY}" ],
      start_error_after: 1,
      start_error: RuntimeError.new("rollback start failed")
    )
    run = repair(store, listed)

    error = assert_raises(REPAIR::Stop) { run.call }

    assert_includes error.message, "job_id=job-1"
    assert_includes error.message, "backup=#{@dir}"
    assert_no_match(/rollback job/, error.message)
    assert_equal @base.b, store.objects[REPAIR::KEY].b
    assert_equal [ REPAIR::KEY, REPAIR::KEY ], store.uploads.map(&:first)
    assert_equal 2, listed.starts.size
    assert_equal [ { job_id: "job-1", data_source_id: REPAIR::DATA_SOURCE_ID, role: "initial" } ], run.ingestions
    assert_includes manifest, "job_id=job-1 role=initial"
    assert_includes manifest, "failure_attribution=target"
    assert_includes manifest, "stage=body_restored"
    assert_not_includes manifest, "role=rollback"
    assert_includes manifest, "aws_error=RuntimeError: rollback start failed"
  end

  test "does not open a rollback ingestion when the restore upload fails" do
    store = memory
    store.fail_second_upload = true
    listed = agent(failed: 1, failure_reasons: [ "could not index #{REPAIR::KEY}" ])

    error = assert_raises(REPAIR::Stop) { repair(store, listed).call }

    assert_match(/rollback upload failed/, error.message)
    assert_equal 1, listed.starts.size
    assert_equal @base.b, @dir.join("chunk_p5_1_before.bin").binread
    assert_equal @candidate.b, store.objects[REPAIR::KEY].b
    assert_not_includes manifest, "role=rollback"
  end

  test "the script aborts before constructing a client and ignores the safety confirm" do
    source = SCRIPT.read
    repair_source = Rails.root.join("app/services/elemont_mh_page5_botonera_branch_repair.rb").read
    assert source.index("abort(") < source.index('require "aws-sdk-bedrockagent"')
    assert_includes source, 'ENV["RAG_PAGE5_BOTONERA_BRANCH_CONFIRM"] == "1"'
    assert_no_match(/queue_adapter\s*=/, source)
    assert_no_match(/queue_adapter\s*=/, repair_source)
    assert_not_includes source, "KbSyncService"
    assert_not_includes source, "BulkKbSyncService"
    assert_not_includes repair_source, "KbSyncService"
    assert_not_includes repair_source, "ElemontMhPage5SafetyNoteRepair.new"
    assert_not_includes repair_source, 'ENV["RAG_PAGE5_SAFETY_NOTE_CONFIRM"]'
    assert_not_includes repair_source, "Aws::"
    assert_not_includes repair_source, "S3DocumentsService"
    assert_not_includes repair_source, "Net::HTTP"

    _stdout, stderr, status = Open3.capture3(
      {
        "PATH" => ENV.fetch("PATH"),
        "HOME" => ENV.fetch("HOME"),
        "RAG_PAGE5_SAFETY_NOTE_CONFIRM" => "1"
      },
      RbConfig.ruby,
      SCRIPT.to_s
    )

    assert_equal 1, status.exitstatus
    assert_includes stderr, "RAG_PAGE5_BOTONERA_BRANCH_CONFIRM=1"
  end

  private

  def memory(body = @base, bucket_name: REPAIR::BUCKET)
    Memory.new(
      { REPAIR::KEY => body, REPAIR::SIDECAR_KEY => SIDECAR.dup },
      bucket_name: bucket_name
    )
  end

  def agent(**)
    Agent.new(**)
  end

  def repair(store, listed, confirm: "1", bucket: REPAIR::BUCKET, knowledge_base_id: REPAIR::KNOWLEDGE_BASE_ID,
             data_source_id: REPAIR::DATA_SOURCE_ID, region: REPAIR::REGION, sleep_for: ->(_) { flunk("slept") })
    REPAIR.new(
      s3: store,
      agent: listed,
      bucket: bucket,
      knowledge_base_id: knowledge_base_id,
      data_source_id: data_source_id,
      region: region,
      backup_dir: @dir,
      confirm: confirm,
      sleep_for: sleep_for
    )
  end

  def manifest
    @dir.join("manifest.txt").read
  end

  def assert_uncertain_after_write(error, store)
    assert_match(/aws error after write/, error.message)
    assert_includes error.message, "backup=#{@dir}"
    assert_no_match(/restor/i, error.message)
    assert_equal [ REPAIR::KEY ], store.uploads.map(&:first)
    assert_equal @candidate.b, store.objects[REPAIR::KEY].b
  end

  def assert_uncertain_outcome(error, store)
    assert_match(/outcome uncertain/, error.message)
    assert_match(/no rollback/, error.message)
    assert_match(/no second job/, error.message)
    assert_includes error.message, "backup=#{@dir}"
    assert_includes error.message, "job_id=job-1"
    assert_no_match(/restor/i, error.message)
    assert_equal [ REPAIR::KEY ], store.uploads.map(&:first)
    assert_equal @candidate.b, store.objects[REPAIR::KEY].b
    assert_equal 1, error.message.scan("job_id=job-1").size
  end

  class Memory
    attr_reader :downloads, :uploads, :objects
    attr_accessor :bucket_name, :sidecar_mutates, :text_lies, :fail_second_upload, :fail_first_upload,
                  :raise_after_upload, :raise_on_upload

    def initialize(objects, bucket_name:)
      @objects = objects
      @bucket_name = bucket_name
      @downloads = []
      @uploads = []
    end

    def download(key)
      @downloads << key
      raise RuntimeError, "read failed" if raise_after_upload && @uploads.any?
      return "mutated-sidecar".b if sidecar_mutates && key.end_with?(".metadata.json") && @uploads.any?
      return "lied-text".b if text_lies && key.end_with?(".txt") && @uploads.any? { |entry| entry[0] == key }

      @objects[key]&.dup
    end

    def upload_text(key, content)
      @uploads << [ key, content.dup ]
      raise RuntimeError, "upload failed" if raise_on_upload && @uploads.size == 1
      return nil if fail_first_upload && @uploads.size == 1
      return nil if fail_second_upload && @uploads.size > 1

      @objects[key] = content.dup
      key
    end
  end

  class Agent
    Summary = Struct.new(:data_source_id)
    List = Struct.new(:data_source_summaries, :next_token)
    Stats = Struct.new(:number_of_documents_failed, :number_of_modified_documents_indexed)
    Job = Struct.new(:ingestion_job_id, :status, :statistics, :failure_reasons)
    Wrap = Struct.new(:ingestion_job)

    attr_reader :lists, :starts, :gets, :manifest_at_get

    def initialize(ids: [ REPAIR::DATA_SOURCE_ID ], statuses: [ "COMPLETE" ], failed: 0, modified: 1,
                   pages: nil, always_next: false, start_error: nil, start_error_after: 0,
                   blank_job_id: false, get_error: nil, get_error_after: 0, manifest_path: nil,
                   failure_reasons: [], statistics: :present)
      @ids = ids
      @statuses = statuses
      @failed = failed
      @modified = modified
      @pages = pages
      @always_next = always_next
      @start_error = start_error
      @start_error_after = start_error_after
      @blank_job_id = blank_job_id
      @get_error = get_error
      @get_error_after = get_error_after
      @manifest_path = manifest_path
      @failure_reasons = failure_reasons
      @statistics = statistics
      @lists = []
      @starts = []
      @gets = []
      @manifest_at_get = nil
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
      raise @start_error if @start_error && @starts.size > @start_error_after
      return Wrap.new(Job.new(nil, nil, nil, [])) if @blank_job_id

      Wrap.new(Job.new("job-#{@starts.size}", nil, nil, []))
    end

    def get_ingestion_job(knowledge_base_id:, data_source_id:, ingestion_job_id:)
      @gets << {
        knowledge_base_id: knowledge_base_id,
        data_source_id: data_source_id,
        ingestion_job_id: ingestion_job_id
      }
      @manifest_at_get = File.read(@manifest_path) if @manifest_path
      raise @get_error if @get_error && @gets.size > @get_error_after

      status = @statuses.fetch(@gets.size - 1, @statuses.last)
      Wrap.new(Job.new(ingestion_job_id, status, stats, @failure_reasons))
    end

    def stats
      return nil if @statistics.nil?

      Stats.new(@failed, @modified)
    end
  end
end
