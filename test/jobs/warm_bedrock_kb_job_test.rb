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

  # Un cliente falso que puede fallar las primeras N veces. Los tests existentes
  # lo llaman sin argumentos y siguen viendo un cliente que siempre responde.
  def with_fake_bedrock_client(raise_times: 0, message: "Aurora cluster is resuming after being auto-paused")
    calls = []
    fake = Object.new
    fake.define_singleton_method(:retrieve) do |**kwargs|
      calls << kwargs
      raise Aws::BedrockAgentRuntime::Errors::ServiceError.new(nil, message) if calls.size <= raise_times
      nil
    end
    orig = Aws::BedrockAgentRuntime::Client.method(:new)
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*_args, **_kwargs| fake }
    yield calls
  ensure
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
  end

  # `sleep_for` es un module_function de AuroraColdStartRetry (línea 22) y
  # `with_retry` lo llama sobre el módulo, así que sobreescribir el método
  # singleton basta. Sin esto la suite duerme 90 segundos reales.
  def without_sleeping
    slept = []
    orig = Bedrock::AuroraColdStartRetry.method(:sleep_for)
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for) { |s| slept << s }
    yield slept
  ensure
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for, orig)
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

  test "perform logs a kb_warm_ping PILOT_USAGE line" do
    log_output = StringIO.new
    capture_logger = ActiveSupport::Logger.new(log_output)
    Rails.logger.broadcast_to(capture_logger)

    with_fake_bedrock_client do
      WarmBedrockKbJob.perform_now
    end

    line = log_output.string.lines.find { |l| l.include?("[PILOT_USAGE]") && l.include?('"event":"kb_warm_ping"') }
    assert line, "kb_warm_ping PILOT_USAGE line must be logged"
    payload = JSON.parse(line.split("[PILOT_USAGE] ", 2).last)
    assert_equal "kb_warm_ping", payload["route"]
    assert_equal "ok", payload["result"]
    assert payload["latency_ms"].present?
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger) if capture_logger
  end

  test "perform skips retrieve when throttle key exists" do
    with_fake_bedrock_client do |calls|
      Rails.cache.write(THROTTLE_KEY, Time.current.to_i, expires_in: 4.minutes)
      WarmBedrockKbJob.perform_now
      assert_empty calls
    end
  end

  test "reintenta el cold-start de Aurora y termina precalentando" do
    log_output = StringIO.new
    capture_logger = ActiveSupport::Logger.new(log_output)
    Rails.logger.broadcast_to(capture_logger)

    without_sleeping do |slept|
      with_fake_bedrock_client(raise_times: 1) do |calls|
        WarmBedrockKbJob.perform_now
        assert_equal 2, calls.size
        assert_equal [ 15 ], slept
      end
    end

    line = log_output.string.lines.find { |l| l.include?("[PILOT_USAGE]") && l.include?('"event":"kb_warm_ping"') }
    assert line, "kb_warm_ping PILOT_USAGE line must be logged after a successful retry"
    assert_equal "ok", JSON.parse(line.split("[PILOT_USAGE] ", 2).last)["result"]
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger) if capture_logger
  end

  test "agota los tres reintentos sin re-encolar" do
    log_output = StringIO.new
    capture_logger = ActiveSupport::Logger.new(log_output)
    Rails.logger.broadcast_to(capture_logger)

    without_sleeping do |slept|
      with_fake_bedrock_client(raise_times: 4) do |calls|
        assert_no_enqueued_jobs do
          WarmBedrockKbJob.perform_now
        end
        assert_equal 4, calls.size
        assert_equal [ 15, 30, 45 ], slept
      end
    end

    assert log_output.string.include?("[KB_WARM] discarded:"), "debe loguear el discard"
  ensure
    Rails.logger.stop_broadcasting_to(capture_logger) if capture_logger
  end

  test "reclama el throttle antes de llamar, no después" do
    without_sleeping do
      with_fake_bedrock_client(raise_times: 4) do
        WarmBedrockKbJob.perform_now
        assert Rails.cache.exist?(THROTTLE_KEY)
      end
    end
  end

  test "un error que no es de Aurora se propaga sin dormir" do
    without_sleeping do |slept|
      with_fake_bedrock_client(raise_times: 1, message: "The security token included in the request is invalid") do |calls|
        WarmBedrockKbJob.perform_now
        assert_equal 1, calls.size
        assert_empty slept
      end
    end
  end
end
