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
  end

  teardown do
    ENV.delete('BEDROCK_KNOWLEDGE_BASE_ID')
    ENV.delete('AWS_REGION')
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
      job_id = service.sync!

      assert_equal TEST_JOB_ID, job_id
    end
  end

  test 'falls back to env var when kb_id is nil' do
    with_fake_agent_client do |_client|
      service = KbSyncService.new
      job_id = service.sync!

      assert_equal TEST_JOB_ID, job_id
    end
  end

  test 'ignores blank kb_id and falls back to env var' do
    with_fake_agent_client do |_client|
      service = KbSyncService.new(kb_id: '')
      job_id = service.sync!

      assert_equal TEST_JOB_ID, job_id
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

  test 'sync! returns ingestion job id on success' do
    with_fake_agent_client do |_client|
      service = KbSyncService.new
      job_id = service.sync!

      assert_equal TEST_JOB_ID, job_id
    end
  end

  test 'sync! returns nil when no data sources exist' do
    with_fake_agent_client do |client|
      client.data_sources = []
      service = KbSyncService.new

      assert_nil service.sync!
    end
  end

  test 'sync! returns nil when list_data_sources fails' do
    with_fake_agent_client do |client|
      client.should_raise_on_list = true
      service = KbSyncService.new

      assert_nil service.sync!
    end
  end

  test 'sync! returns nil when start_ingestion_job fails' do
    with_fake_agent_client do |client|
      client.should_raise_on_ingest = true
      service = KbSyncService.new

      assert_nil service.sync!
    end
  end
end
