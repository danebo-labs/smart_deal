# frozen_string_literal: true

require "test_helper"
require "ostruct"

class IngestionStatusServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  TEST_KB_ID = "test-kb-id"
  TEST_DS_ID = "test-ds-id"
  TEST_JOB_ID = "ingestion-job-123"

  setup do
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = TEST_KB_ID
    ENV["AWS_REGION"] = "us-east-1"
    ENV.delete("BEDROCK_DATA_SOURCE_ID")
  end

  teardown do
    ENV.delete("BEDROCK_KNOWLEDGE_BASE_ID")
    ENV.delete("AWS_REGION")
    ENV.delete("BEDROCK_DATA_SOURCE_ID")
  end

  class FakeBedrockAgentClient
    attr_accessor :should_raise_on_list, :data_sources, :pages
    attr_reader :job_calls, :list_calls

    def initialize(*)
      @should_raise_on_list = false
      @data_sources = [ OpenStruct.new(data_source_id: TEST_DS_ID) ]
      @pages = nil
      @job_calls = []
      @list_calls = []
    end

    def list_data_sources(**params)
      @list_calls << params
      raise StandardError, "List data sources error" if @should_raise_on_list

      return @pages[params[:next_token]] if @pages

      OpenStruct.new(data_source_summaries: @data_sources, next_token: nil)
    end

    def get_ingestion_job(**params)
      @job_calls << params
      OpenStruct.new(ingestion_job: OpenStruct.new(status: "COMPLETE", failure_reasons: []))
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

  test "reads status from the configured data source when it is listed" do
    with_env_vars("BEDROCK_DATA_SOURCE_ID" => "preferred-ds") do
      with_fake_agent_client do |client|
        client.data_sources = [
          OpenStruct.new(data_source_id: "other-ds"),
          OpenStruct.new(data_source_id: "preferred-ds")
        ]
        status = IngestionStatusService.new.job_status(TEST_JOB_ID)

        assert_equal "COMPLETE", status
        assert_equal "preferred-ds", client.job_calls.first[:data_source_id]
      end
    end
  end

  test "does not read a job when the configured data source is absent" do
    messages = []
    original_error = Rails.logger.method(:error)
    Rails.logger.define_singleton_method(:error) { |*args| messages << args.join(" ") }

    with_env_vars("BEDROCK_DATA_SOURCE_ID" => "missing-ds") do
      with_fake_agent_client do |client|
        client.data_sources = [ OpenStruct.new(data_source_id: TEST_DS_ID) ]
        service = IngestionStatusService.new(data_source_id: "missing-ds")

        assert_nil service.job_status(TEST_JOB_ID)
        assert_empty client.job_calls
        assert_nil service.resolved_data_source_id
      end
    end

    assert messages.any? { |line| line.include?("missing-ds") && line.include?("was not read") }
  ensure
    Rails.logger.define_singleton_method(:error, original_error)
  end

  test "returns nil when the knowledge base lists no data sources" do
    with_fake_agent_client do |client|
      client.data_sources = []
      service = IngestionStatusService.new(data_source_id: "missing-ds")

      assert_nil service.resolved_data_source_id
      assert_empty client.job_calls
    end
  end

  test "returns nil when listing data sources fails" do
    with_fake_agent_client do |client|
      client.should_raise_on_list = true
      service = IngestionStatusService.new(data_source_id: TEST_DS_ID)

      assert_nil service.job_status(TEST_JOB_ID)
      assert_empty client.job_calls
    end
  end

  test "finds the configured data source on a later page" do
    page = Struct.new(:data_source_summaries, :next_token)
    with_fake_agent_client do |client|
      client.pages = {
        nil => page.new([ OpenStruct.new(data_source_id: "other-ds") ], "p2"),
        "p2" => page.new([ OpenStruct.new(data_source_id: "preferred-ds") ], nil)
      }
      service = IngestionStatusService.new(data_source_id: "preferred-ds")

      assert_equal "preferred-ds", service.resolved_data_source_id
      assert_equal [ nil, "p2" ], client.list_calls.pluck(:next_token)
      assert_equal "COMPLETE", service.job_status(TEST_JOB_ID)
      assert_equal "preferred-ds", client.job_calls.first[:data_source_id]
    end
  end

  test "returns nil when the data source list does not finish" do
    page = Struct.new(:data_source_summaries, :next_token)
    with_fake_agent_client do |client|
      client.pages = Hash.new { |_pages, token| page.new([ OpenStruct.new(data_source_id: "other") ], "next-#{token}") }
      service = IngestionStatusService.new(data_source_id: "preferred-ds")

      assert_nil service.resolved_data_source_id
      assert_empty client.job_calls
    end
  end

  test "uses the first listed data source when none is configured" do
    with_fake_agent_client do |client|
      client.data_sources = [
        OpenStruct.new(data_source_id: "first-ds"),
        OpenStruct.new(data_source_id: "second-ds")
      ]

      assert_equal "first-ds", IngestionStatusService.new.resolved_data_source_id
    end
  end
end
