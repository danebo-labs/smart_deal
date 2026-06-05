# frozen_string_literal: true

require "test_helper"
require "ostruct"

class BulkKbSyncServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  BULK_DS_ID = "8DUTRUCDTS"
  TEST_JOB_ID = "ingestion-bulk-abc"

  # ---------------------------------------------------------------------------
  # Fake KbSyncService
  # ---------------------------------------------------------------------------

  class FakeKbSyncService
    attr_reader :last_call_args, :last_data_source_id

    def initialize(data_source_id: nil)
      @last_data_source_id = data_source_id
      @last_call_args      = nil
    end

    def sync!(uploaded_filenames: [], locale: nil)
      @last_call_args = { uploaded_filenames: uploaded_filenames }
      { job_id: TEST_JOB_ID, kb_id: "kb-123", data_source_id: @last_data_source_id }
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  setup do
    ENV["BEDROCK_BULK_DATA_SOURCE_ID"] = BULK_DS_ID
  end

  teardown do
    ENV.delete("BEDROCK_BULK_DATA_SOURCE_ID")
  end

  test "delegates to KbSyncService and returns job info" do
    fake     = FakeKbSyncService.new(data_source_id: BULK_DS_ID)
    service  = BulkKbSyncService.new(kb_sync_service: fake)
    result   = service.sync!(uploaded_filenames: [ "Pump Manual", "Relay Spec" ])

    assert_equal TEST_JOB_ID, result[:job_id]
    assert_equal [ "Pump Manual", "Relay Spec" ], fake.last_call_args[:uploaded_filenames]
  end

  test "builds KbSyncService with BEDROCK_BULK_DATA_SOURCE_ID from ENV" do
    captured_ds_id = nil
    original_new   = KbSyncService.method(:new)

    KbSyncService.define_singleton_method(:new) do |*_args, data_source_id: nil, **_kwargs|
      captured_ds_id = data_source_id
      fake_service = Object.new
      fake_service.define_singleton_method(:sync!) { |**_kw| { job_id: "job-x", kb_id: "kb-x", data_source_id: data_source_id } }
      fake_service
    end

    BulkKbSyncService.new.sync!

    assert_equal BULK_DS_ID, captured_ds_id
  ensure
    KbSyncService.define_singleton_method(:new) { |*a, **kw| original_new.call(*a, **kw) }
  end

  test "returns nil when underlying KbSyncService returns nil" do
    fake = Object.new
    fake.define_singleton_method(:sync!) { |**_kw| nil }

    result = BulkKbSyncService.new(kb_sync_service: fake).sync!
    assert_nil result
  end
end
