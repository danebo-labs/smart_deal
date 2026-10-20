# frozen_string_literal: true

require "test_helper"

class Rag::TurnInterpreterFailureTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  SECRET = "Authorization: Bearer secret AKIAIOSFODNN7EXAMPLE"

  test "preparing the client is not a transport failure" do
    error = Timeout::Error.new(SECRET)
    original = BedrockClient.method(:new)
    result = nil
    events = []
    BedrockClient.define_singleton_method(:new) { |*| raise error }
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      events = Rag::ValidationCapture.capture do
        result = interpret("la puerta no cierra", client: nil)
      end
    end

    assert_equal "prepare", result.stage
    assert_equal "local_error", result.status
    assert_not_equal "timeout", result.status
    assert_equal 0, result.input_tokens
    assert_equal 0, result.output_tokens
    assert_secret_free(result, events)
  ensure
    BedrockClient.define_singleton_method(:new) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) } if original
  end

  test "a converse timeout retries and ends as a service failure" do
    error = Timeout::Error.new(SECRET)
    result = nil
    events = []
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      events = Rag::ValidationCapture.capture do
        result = interpret("la puerta no cierra", client: RaisingClient.new(error), sleeper: ->(_) { })
      end
    end

    failures = events.select { |row| row["kind"] == "interpreter_failure" }
    assert_equal [ "retry", "retry", "exhausted" ], failures.pluck("result")
    assert_equal [ 1, 2, 3 ], failures.pluck("attempt")
    assert_equal "service_failure", result.status
    assert_equal "converse", result.stage
    assert_equal "timeout", failures.last["failure_kind"]
    assert_equal true, failures.last["retryable"]
    assert_equal 8, failures.last["read_timeout_seconds"]
    assert_equal "configured", failures.last["read_timeout_provenance"]
    assert_equal 1, failures.last["sdk_max_attempts"]
    assert_equal 0, failures.last["sdk_retry_limit"]
    assert_equal 0, result.input_tokens
    assert_equal 0, result.output_tokens
    assert_equal "cid-timeout", failures.last["correlation_id"]
    assert_secret_free(result, events)
  end

  test "a failure while reading the response is extract and records usage once" do
    result = nil
    events = []
    assert_enqueued_jobs 1, only: TrackBedrockQueryJob do
      events = Rag::ValidationCapture.capture do
        result = interpret("la puerta no cierra", client: OutputFailingClient.new(input_tokens: 9, output_tokens: 4))
      end
    end

    assert_equal "extract", result.stage
    assert_equal "local_error", result.status
    assert_not_equal "transport_error", result.status
    assert_equal 9, result.input_tokens
    assert_equal 4, result.output_tokens
    assert_equal 1, enqueued_jobs.count { |entry| entry[:job] == TrackBedrockQueryJob }
    assert_equal 9, job_args[:input_tokens]
    assert_equal 4, job_args[:output_tokens]
    assert_nil job_args[:cost]
    assert_secret_free(result, events)
    assert_equal "extract", events.find { |row| row["kind"] == "interpreter_failure" }["stage"]
  end

  test "a failure while building the perception records usage once and does not invent tokens" do
    original = Rag::TurnPerception.method(:build)
    paid = nil
    unpaid = nil
    Rag::TurnPerception.define_singleton_method(:build) { |*, **| raise SECRET }
    assert_enqueued_jobs 1, only: TrackBedrockQueryJob do
      paid = interpret(
        "la puerta no cierra",
        client: ToolClient.new(valid_tool, input_tokens: 6, output_tokens: 1),
        correlation_id: "cid-paid"
      )
    end
    clear_enqueued_jobs
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      unpaid = interpret(
        "la puerta no cierra",
        client: ToolClient.new(valid_tool, input_tokens: 0, output_tokens: 0),
        correlation_id: "cid-unpaid"
      )
    end

    assert_equal "perception", paid.stage
    assert_equal "local_error", paid.status
    assert_equal 6, paid.input_tokens
    assert_equal 1, paid.output_tokens
    assert_equal "perception", unpaid.stage
    assert_equal "local_error", unpaid.status
    assert_equal 0, unpaid.input_tokens
    assert_equal 0, unpaid.output_tokens
    assert_not_includes paid.error_reason, "AKIA"
  ensure
    Rag::TurnPerception.define_singleton_method(:build) { |*args, **kwargs| original.call(*args, **kwargs) } if original
  end

  test "a transient service error retries and then keeps the perception" do
    error = ServiceUnavailableException.new("Bedrock is unable to process your request.")
    waits = []
    client = SequenceClient.new([ error, error, valid_tool ])
    result = nil
    events = []
    assert_enqueued_jobs 1, only: TrackBedrockQueryJob do
      events = Rag::ValidationCapture.capture do
        result = interpret(
          "la puerta no cierra",
          client: client,
          sleeper: ->(seconds) { waits << seconds },
          correlation_id: "cid-retry"
        )
      end
    end

    assert_equal "ok", result.status
    assert_equal [ 0.4, 1.2 ], waits
    assert_equal 3, client.calls
    assert_equal [ "retry", "retry" ], events.select { |row| row["kind"] == "interpreter_failure" }.pluck("result")
    assert_equal 1, events.count { |row| row["kind"] == "interpreter_response" }
    assert_equal [ 1, 2, 3 ], events.select { |row| row["kind"] == "interpreter_attempt" }.pluck("attempt")
    assert_equal "la puerta no cierra", result.perception.observations.first
  end

  test "an exhausted service error records the provider fields and does not return a perception" do
    response = Object.new
    response.define_singleton_method(:status_code) { 503 }
    response.define_singleton_method(:headers) { { "x-amzn-requestid" => "req-vf5" } }
    context = Object.new
    context.define_singleton_method(:http_response) { response }
    error = ServiceUnavailableException.new("Bedrock is unable to process your request.")
    error.define_singleton_method(:context) { context }
    events = Rag::ValidationCapture.capture do
      result = interpret("la puerta no cierra", client: RaisingClient.new(error), sleeper: ->(_) { }, correlation_id: "cid-down")
      assert_nil result.perception
      assert_equal "service_failure", result.status
    end

    failure = events.select { |row| row["kind"] == "interpreter_failure" }.last
    assert_equal "exhausted", failure["result"]
    assert_equal "service", failure["failure_kind"]
    assert_equal 503, failure["http_status"]
    assert_equal "observed", failure["http_status_provenance"]
    assert_equal "req-vf5", failure["request_id"]
    assert_equal 3, failure["attempt"]
  end

  test "an access error is not retried" do
    error = AccessDeniedException.new("denied")
    waits = []
    client = RaisingClient.new(error)
    result = interpret("la puerta no cierra", client: client, sleeper: ->(seconds) { waits << seconds })

    assert_equal "access_denied", result.status
    assert_empty waits
    assert_equal 1, client.calls
  end

  test "each transient converse is one budget admission" do
    previous = %w[RAG_LOCAL_PASS_GUARD RAG_LOCAL_PASS_CALL_CAP RAG_LOCAL_PASS_COST_CAP_USD AWS_MAX_ATTEMPTS].index_with { |key| ENV[key] }
    ENV["RAG_LOCAL_PASS_GUARD"] = "1"
    ENV["RAG_LOCAL_PASS_CALL_CAP"] = "16"
    ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = "1"
    ENV["AWS_MAX_ATTEMPTS"] = "1"
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
    error = ServiceUnavailableException.new("Bedrock is unable to process your request.")
    client = AdmittingClient.new(error)
    interpret("la puerta no cierra", client: client, sleeper: ->(_) { })

    assert Rag::LocalPassLedger.armed?
    assert_equal 3, client.calls
    assert_equal 3, Rag::LocalPassLedger.snapshot["attempts"]
  ensure
    previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
  end

  test "an invalid tool payload is a contract result and not an exception" do
    result = nil
    events = []
    assert_enqueued_jobs 1, only: TrackBedrockQueryJob do
      events = Rag::ValidationCapture.capture do
        result = interpret(
          "la puerta no cierra",
          client: ToolClient.new(valid_tool.merge("route" => "ready"), input_tokens: 3, output_tokens: 1)
        )
      end
    end

    assert result.fallback
    assert_equal "invalid_schema", result.status
    assert_nil result.error_class
    assert_nil result.stage
    assert_nil result.error_reason
    assert events.none? { |row| row["kind"] == "interpreter_failure" }
    assert events.any? { |row| row["kind"] == "perception_applied" && row["valid"] == false }
    assert_equal 3, result.input_tokens
    assert_equal 3, job_args[:input_tokens]
    assert_equal 1, job_args[:output_tokens]
  end

  test "a successful response still records an attempt when usage tracking fails" do
    original = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| raise "tracking unavailable" }
    result = nil
    events = Rag::ValidationCapture.capture do
      result = interpret("la puerta no cierra", client: ToolClient.new(valid_tool, input_tokens: 6, output_tokens: 2))
    end

    assert_equal "ok", result.status
    assert_equal 1, events.count { |event| event["kind"] == "interpreter_attempt" }
    assert_equal 1, events.find { |event| event["kind"] == "interpreter_attempt" }["attempt"]
    assert_equal 6, result.input_tokens
    assert events.none? { |event| event["kind"] == "interpreter_failure" }
  ensure
    job = TrackBedrockQueryJob.singleton_class
    job.send(:remove_method, :perform_later) if original && job.instance_methods(false).include?(:perform_later)
  end

  private

  def interpret(turn, client:, correlation_id: "cid-timeout", sleeper: nil)
    Rag::TurnInterpreter.call(
      turn: turn,
      episode: Rag::ActiveEpisode.new,
      viewer_account: nil,
      correlation_id: correlation_id,
      attribution: {},
      client: client,
      sleeper: sleeper
    )
  end

  def valid_tool
    {
      "move" => "report",
      "assertions" => [],
      "observations" => [ "la puerta no cierra" ],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def job_args
    job = enqueued_jobs.reverse.find { |entry| entry[:job] == TrackBedrockQueryJob }
    job[:args].last.to_h.symbolize_keys
  end

  def assert_secret_free(result, events)
    blob = [ result.error_reason, events ].to_json
    assert_not_includes blob, "AKIA"
    assert_not_includes blob, "Bearer"
    assert_not_includes blob, "secret"
  end

  class ServiceUnavailableException < StandardError; end
  class AccessDeniedException < StandardError; end

  class RaisingClient
    attr_reader :calls

    def initialize(error)
      @error = error
      @calls = 0
    end

    def converse(*)
      @calls += 1
      raise @error
    end
  end

  class SequenceClient
    attr_reader :calls

    def initialize(steps)
      @steps = steps.dup
      @calls = 0
    end

    def converse(*)
      @calls += 1
      step = @steps.shift
      raise step if step.is_a?(Exception)

      tool = Struct.new(:name, :input).new("turn_perception", step)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(4, 2)
      Struct.new(:output, :usage).new(output, usage)
    end
  end

  class AdmittingClient
    attr_reader :calls

    def initialize(error)
      @error = error
      @calls = 0
    end

    def converse(*)
      Rag::LocalPassLedger.protect!(
        operation: "converse",
        model_id: Rag::TurnInterpreter::MODEL_ID,
        input_tokens: 20,
        output_tokens: 20
      ) do
        @calls += 1
        raise @error
      end
    end
  end

  class OutputFailingClient
    def initialize(input_tokens:, output_tokens:)
      @input_tokens = input_tokens
      @output_tokens = output_tokens
    end

    def converse(*)
      usage = Struct.new(:input_tokens, :output_tokens).new(@input_tokens, @output_tokens)
      output = Object.new
      def output.message
        raise "output read Authorization: Bearer secret AKIAIOSFODNN7EXAMPLE"
      end
      Struct.new(:output, :usage).new(output, usage)
    end
  end

  class ToolClient
    def initialize(tool_input, input_tokens:, output_tokens:)
      @tool_input = tool_input
      @input_tokens = input_tokens
      @output_tokens = output_tokens
    end

    def converse(*)
      tool = Struct.new(:name, :input).new("turn_perception", @tool_input)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(@input_tokens, @output_tokens)
      Struct.new(:output, :usage).new(output, usage)
    end
  end
end
