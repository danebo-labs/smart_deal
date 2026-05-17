# frozen_string_literal: true

require 'test_helper'
require 'ostruct'

class KbSyncServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  TEST_KB_ID = 'test-kb-id'
  TEST_DS_ID = 'test-ds-id'
  TEST_JOB_ID = 'ingestion-job-123'

  setup do
    ENV['BEDROCK_KNOWLEDGE_BASE_ID'] = TEST_KB_ID
    ENV['AWS_REGION'] = 'us-east-1'
    ENV.delete('BEDROCK_DATA_SOURCE_ID')
  end

  teardown do
    ENV.delete('BEDROCK_KNOWLEDGE_BASE_ID')
    ENV.delete('AWS_REGION')
    ENV.delete('BEDROCK_DATA_SOURCE_ID')
  end

  class FakeBedrockAgentClient
    attr_accessor :should_raise_on_list, :should_raise_on_ingest, :data_sources

    def initialize(*)
      @should_raise_on_list = false
      @should_raise_on_ingest = false
      @data_sources = [ OpenStruct.new(data_source_id: TEST_DS_ID) ]
    end

    def list_data_sources(_params)
      raise StandardError, 'List data sources error' if @should_raise_on_list

      OpenStruct.new(data_source_summaries: @data_sources)
    end

    def start_ingestion_job(_params)
      raise StandardError, 'Ingestion error' if @should_raise_on_ingest

      OpenStruct.new(
        ingestion_job: OpenStruct.new(
          ingestion_job_id: TEST_JOB_ID,
          status: 'STARTING'
        )
      )
    end
  end

  def with_fake_agent_client
    fake_client = FakeBedrockAgentClient.new
    original_new = Aws::BedrockAgent::Client.method(:new)
    Aws::BedrockAgent::Client.define_singleton_method(:new) { |*_args| fake_client }
    yield fake_client
  ensure
    Aws::BedrockAgent::Client.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  def with_env_vars(vars)
    original = {}
    vars.each do |key, value|
      original[key] = ENV.fetch(key, nil)
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # ============================================
  # Injectable kb_id
  # ============================================

  test 'uses injected kb_id over env var' do
    with_fake_agent_client do |_client|
      service = KbSyncService.new(kb_id: 'injected-kb-id')
      result = service.sync!

      assert_equal TEST_JOB_ID, result[:job_id]
      assert_equal 'injected-kb-id', result[:kb_id]
      assert_equal TEST_DS_ID, result[:data_source_id]
    end
  end

  test 'falls back to env var when kb_id is nil' do
    with_fake_agent_client do |_client|
      service = KbSyncService.new
      result = service.sync!

      assert_equal TEST_JOB_ID, result[:job_id]
      assert_equal TEST_DS_ID, result[:data_source_id]
    end
  end

  test 'ignores blank kb_id and falls back to env var' do
    with_fake_agent_client do |_client|
      service = KbSyncService.new(kb_id: '')
      result = service.sync!

      assert_equal TEST_JOB_ID, result[:job_id]
    end
  end

  # ============================================
  # sync! behavior
  # ============================================

  test 'sync! returns nil when kb_id is not configured' do
    original_credentials = Rails.application.credentials
    stub_credentials = Object.new
    stub_credentials.define_singleton_method(:dig) do |*keys|
      return nil if keys == [ :bedrock, :knowledge_base_id ]
      original_credentials.dig(*keys)
    end
    original_method = Rails.application.method(:credentials)
    Rails.application.define_singleton_method(:credentials) { stub_credentials }

    with_env_vars('BEDROCK_KNOWLEDGE_BASE_ID' => nil) do
      with_fake_agent_client do |_client|
        service = KbSyncService.new
        assert_nil service.sync!
      end
    end
  ensure
    Rails.application.define_singleton_method(:credentials, original_method)
  end

  test 'sync! returns hash with job_id kb_id data_source_id on success' do
    with_fake_agent_client do |_client|
      service = KbSyncService.new
      result = service.sync!

      assert_equal TEST_JOB_ID, result[:job_id]
      assert_equal TEST_KB_ID, result[:kb_id]
      assert_equal TEST_DS_ID, result[:data_source_id]
    end
  end

  test 'sync! returns nil when no data sources exist' do
    with_fake_agent_client do |client|
      client.data_sources = []
      service = KbSyncService.new

      assert_nil service.sync!
    end
  end

  test 'sync! re-raises when list_data_sources fails' do
    with_fake_agent_client do |client|
      client.should_raise_on_list = true
      service = KbSyncService.new

      assert_raises(StandardError) { service.sync! }
    end
  end

  test 'sync! re-raises when start_ingestion_job fails' do
    with_fake_agent_client do |client|
      client.should_raise_on_ingest = true
      service = KbSyncService.new

      assert_raises(StandardError) { service.sync! }
    end
  end

  # ============================================
  # Preferred data source logic
  # ============================================

  test 'uses preferred data source when it exists in list' do
    preferred_id = 'preferred-ds-id'
    other_id = 'other-ds-id'

    with_env_vars('BEDROCK_DATA_SOURCE_ID' => preferred_id) do
      with_fake_agent_client do |client|
        client.data_sources = [
          OpenStruct.new(data_source_id: other_id),
          OpenStruct.new(data_source_id: preferred_id)
        ]
        service = KbSyncService.new
        result = service.sync!

        assert_equal TEST_JOB_ID, result[:job_id]
        assert_equal preferred_id, result[:data_source_id]
      end
    end
  end

  test 'falls back to first data source when preferred not found' do
    with_env_vars('BEDROCK_DATA_SOURCE_ID' => 'nonexistent-ds-id') do
      with_fake_agent_client do |client|
        client.data_sources = [ OpenStruct.new(data_source_id: TEST_DS_ID) ]
        service = KbSyncService.new
        result = service.sync!

        assert_equal TEST_JOB_ID, result[:job_id]
      end
    end
  end

  test 'uses first data source when no preferred data source configured' do
    with_fake_agent_client do |client|
      client.data_sources = [
        OpenStruct.new(data_source_id: 'first-ds'),
        OpenStruct.new(data_source_id: 'second-ds')
      ]
      service = KbSyncService.new
      result = service.sync!

      assert_equal TEST_JOB_ID, result[:job_id]
      assert_equal 'first-ds', result[:data_source_id]
    end
  end

  # ============================================
  # Aurora cold-start retry (Fix 2)
  # ============================================

  class AuroraColdStartFakeClient < FakeBedrockAgentClient
    attr_accessor :fail_count

    def initialize(*)
      super
      @fail_count = 1
      @calls = 0
    end

    def start_ingestion_job(params)
      @calls += 1
      if @calls <= @fail_count
        raise Aws::BedrockAgent::Errors::ServiceError.new(
          nil,
          "resuming after being auto-paused"
        )
      end
      super
    end
  end

  def with_fast_aurora_sleep
    orig = Bedrock::AuroraColdStartRetry.method(:sleep_for)
    sleep_calls = []
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for) { |n| sleep_calls << n }
    yield sleep_calls
  ensure
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for, orig)
  end

  test 'retries once on Aurora cold-start and succeeds' do
    fake_client = AuroraColdStartFakeClient.new
    original_new = Aws::BedrockAgent::Client.method(:new)
    Aws::BedrockAgent::Client.define_singleton_method(:new) { |*_args| fake_client }

    with_fast_aurora_sleep do |sleep_calls|
      service = KbSyncService.new
      result = service.sync!(uploaded_filenames: [ 'pump.pdf' ])
      assert_equal TEST_JOB_ID, result[:job_id]
      assert_equal [ 15 ], sleep_calls, "expected exactly one retry sleep of 15s"
    end
  ensure
    Aws::BedrockAgent::Client.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end

  test 'broadcasts retrying on Aurora cold-start' do
    fake_client = AuroraColdStartFakeClient.new
    original_new = Aws::BedrockAgent::Client.method(:new)
    Aws::BedrockAgent::Client.define_singleton_method(:new) { |*_args| fake_client }

    broadcasts = []
    orig_broadcast = ActionCable.server.method(:broadcast)
    ActionCable.server.define_singleton_method(:broadcast) do |channel, payload|
      broadcasts << payload if channel == "kb_sync"
    end

    with_fast_aurora_sleep do |_sleep_calls|
      service = KbSyncService.new
      service.sync!(uploaded_filenames: [ 'pump.pdf' ])
    end

    retrying = broadcasts.find { |b| b[:status] == "retrying" }
    assert retrying, "expected a retrying broadcast"
    assert_equal [ 'pump.pdf' ], retrying[:filenames]
    assert_equal 1, retrying[:attempt]
  ensure
    Aws::BedrockAgent::Client.define_singleton_method(:new) { |*args| original_new.call(*args) }
    ActionCable.server.define_singleton_method(:broadcast, orig_broadcast)
  end

  test 'raises after exhausting all retry attempts' do
    fake_client = AuroraColdStartFakeClient.new
    fake_client.fail_count = 10
    original_new = Aws::BedrockAgent::Client.method(:new)
    Aws::BedrockAgent::Client.define_singleton_method(:new) { |*_args| fake_client }

    with_fast_aurora_sleep do |_sleep_calls|
      service = KbSyncService.new
      assert_raises(Aws::BedrockAgent::Errors::ServiceError) { service.sync! }
    end
  ensure
    Aws::BedrockAgent::Client.define_singleton_method(:new) { |*args| original_new.call(*args) }
  end
end
