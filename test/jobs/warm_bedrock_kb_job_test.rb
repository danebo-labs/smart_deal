# frozen_string_literal: true

require "test_helper"

class WarmBedrockKbJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  THROTTLE_KEY = WarmBedrockKbJob::THROTTLE_KEY

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @prev_kb = ENV["BEDROCK_KNOWLEDGE_BASE_ID"]
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "kb-test-123"
  end

  teardown do
    Rails.cache = @previous_cache
    if @prev_kb
      ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = @prev_kb
    else
      ENV.delete("BEDROCK_KNOWLEDGE_BASE_ID")
    end
  end

  def with_fake_bedrock_client
    calls = []
    fake = Object.new
    fake.define_singleton_method(:retrieve) { |**kwargs| calls << kwargs }
    orig = Aws::BedrockAgentRuntime::Client.method(:new)
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*_args, **_kwargs| fake }
    yield calls
  ensure
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
  end

  test "enqueues on the default queue" do
    assert_enqueued_with(job: WarmBedrockKbJob, queue: "default") do
      WarmBedrockKbJob.perform_later
    end
  end

  test "perform issues retrieve and sets throttle when not cached" do
    with_fake_bedrock_client do |calls|
      WarmBedrockKbJob.perform_now
      assert_equal 1, calls.size
      assert_equal "kb-test-123", calls.first[:knowledge_base_id]
      assert Rails.cache.exist?(THROTTLE_KEY)
    end
  end

  test "perform skips retrieve when throttle key exists" do
    with_fake_bedrock_client do |calls|
      Rails.cache.write(THROTTLE_KEY, Time.current.to_i, expires_in: 4.minutes)
      WarmBedrockKbJob.perform_now
      assert_empty calls
    end
  end
end
