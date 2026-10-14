# frozen_string_literal: true

require "test_helper"
require "open3"
require "timeout"

class Rag::Phase4WebCheckTest < ActiveSupport::TestCase
  setup do
    disarm_validation_budgets
    Thread.current[:rag_validation_capture] = nil
  end

  teardown do
    disarm_validation_budgets
    Thread.current[:rag_validation_capture] = nil
  end

  test "two requests keep one process budget and the next calls stay unsent" do
    budget = Rag::Phase4WebCheck::Budget
    budget.arm!
    model_calls = { n: 0 }
    retrieve_calls = 0
    client = converse_client(model_calls)
    service = retrieve_service { retrieve_calls += 1 }

    2.times { client.converse({}) }
    service.send(:retrieve_with_retry, { query: "uno" })
    assert_equal 2, budget.model_attempts
    assert_equal 1, budget.logical
    assert_equal 1, budget.logical_physical
    assert_equal 2, model_calls[:n]
    assert_equal 1, retrieve_calls

    2.times { client.converse({}) }
    service.send(:retrieve_with_retry, { query: "dos" })
    assert_equal 4, budget.model_attempts
    assert_equal 2, budget.logical
    assert_equal 4, model_calls[:n]
    assert_equal 2, retrieve_calls

    assert_raises(budget::Stop) { service.send(:retrieve_with_retry, { query: "tres" }) }
    assert_equal 2, retrieve_calls
    assert_equal 2, budget.logical
    assert budget.ledger.any? { |row| row["kind"] == "logical" && row["outcome"] == "blocked" }

    assert_raises(budget::Stop) { client.converse({}) }
    assert_equal 4, model_calls[:n]
    assert_equal 4, budget.model_attempts
    assert_equal 2, budget.logical
  end

  test "the fifth model call is blocked before generate_text sends" do
    budget = Rag::Phase4WebCheck::Budget
    budget.arm!
    invocations = 0
    client = converse_client({ n: 0 })
    aws = Object.new
    aws.define_singleton_method(:invoke_model) { |**| invocations += 1 }
    client.instance_variable_set(:@client, aws)
    4.times { client.converse({}) }

    assert_raises(budget::Stop) { client.generate_text("hola") }
    assert_equal 0, invocations
    assert_equal 4, budget.model_attempts
  end

  test "the fifth physical request of one logical retrieve is blocked before send" do
    budget = Rag::Phase4WebCheck::Budget
    budget.arm!
    retrieve_calls = 0
    service = retrieve_service { retrieve_calls += 1 }

    error = with_five_yields do
      assert_raises(budget::Stop) { service.send(:retrieve_with_retry, { query: "aurora" }) }
    end

    assert_instance_of budget::Stop, error
    assert_equal 4, retrieve_calls
    assert_equal 1, budget.logical
    assert_equal 4, budget.logical_physical
  end

  test "converse is counted once and the fifth call does not reach the sdk" do
    budget = Rag::Phase4WebCheck::Budget
    budget.arm!
    model_calls = { n: 0 }
    client = converse_client(model_calls)

    client.converse({})
    assert_equal 1, model_calls[:n]
    assert_equal 1, budget.model_attempts
    assert_equal 1, budget.ledger.count { |row| row["kind"] == "model" && row["outcome"] == "attempt" }

    3.times { client.converse({}) }
    assert_raises(budget::Stop) { client.converse({}) }
    assert_equal 4, model_calls[:n]
    assert_equal 4, budget.model_attempts
  end

  test "a phase 1 converse wrapper does not count the same invocation twice" do
    budget = Rag::Phase4WebCheck::Budget
    model_calls = { n: 0 }
    client = converse_client(model_calls)
    Rag::Phase1ModelBudget.arm!
    wrapper = Rag::Phase1PinnedTurn::BudgetedConverse.new(client)

    wrapper.converse({})
    assert_equal 1, model_calls[:n]
    assert_equal 1, Rag::Phase1ModelBudget.attempts
    assert_equal 0, budget.model_attempts

    budget.arm!
    wrapper.converse({})
    assert_equal 2, model_calls[:n]
    assert_equal 2, Rag::Phase1ModelBudget.attempts
    assert_equal 1, budget.model_attempts
  end

  test "a model error keeps the attempt and blocks the next send" do
    budget = Rag::Phase4WebCheck::Budget
    budget.arm!
    model_calls = { n: 0 }
    retrieve_calls = 0
    client = converse_client(model_calls)
    client.instance_variable_get(:@converse_client).define_singleton_method(:converse) do |*|
      model_calls[:n] += 1
      raise StandardError, "boom"
    end
    service = retrieve_service { retrieve_calls += 1 }

    assert_raises(budget::Stop) { client.converse({}) }
    assert_equal 1, model_calls[:n]
    assert_equal 1, budget.model_attempts
    assert_predicate budget, :stopped?

    client.instance_variable_get(:@converse_client).define_singleton_method(:converse) do |*|
      model_calls[:n] += 1
      { "ok" => true }
    end
    assert_raises(budget::Stop) { client.converse({}) }
    assert_raises(budget::Stop) { service.send(:retrieve_with_retry, { query: "despues" }) }
    assert_equal 1, model_calls[:n]
    assert_equal 0, retrieve_calls
    assert_equal 1, budget.model_attempts
    assert_equal 0, budget.logical
  end

  test "a retrieve error does not return the physical attempt" do
    budget = Rag::Phase4WebCheck::Budget
    budget.arm!
    service = retrieve_service { raise StandardError, "boom" }

    assert_raises(StandardError) { service.send(:retrieve_with_retry, { query: "falla" }) }
    assert_equal 1, budget.logical
    assert_equal 1, budget.logical_physical
    assert_not_predicate budget, :stopped?

    budget.before_physical!
    assert_equal 2, budget.logical_physical
  end

  test "a disarmed converse keeps the sdk error and does not count" do
    budget = Rag::Phase4WebCheck::Budget
    model_calls = { n: 0 }
    client = converse_client(model_calls)
    client.instance_variable_get(:@converse_client).define_singleton_method(:converse) do |*|
      model_calls[:n] += 1
      raise RuntimeError, "aws"
    end

    error = assert_raises(RuntimeError) { client.converse({}) }
    assert_equal "aws", error.message
    assert_equal 1, model_calls[:n]
    assert_equal 0, budget.model_attempts
    assert_not_predicate budget, :stopped?
    assert_nil client.send(:armed_validation_budget)
  end

  test "a disarmed retrieve does not count a logical call" do
    budget = Rag::Phase4WebCheck::Budget
    retrieve_calls = 0
    service = retrieve_service { retrieve_calls += 1 }

    service.send(:retrieve_with_retry, { query: "habitual" })
    assert_equal 1, retrieve_calls
    assert_equal 0, budget.logical
    assert_equal 0, budget.logical_physical
    assert_nil service.send(:armed_retrieve_limit)
  end

  test "phase 4 wins while armed and the closed budgets remain when it is not" do
    budget = Rag::Phase4WebCheck::Budget
    client = BedrockClient.allocate
    service = BedrockRagService.allocate
    Rag::Phase1PinnedTurn
    Rag::Phase2PinnedTurn
    Rag::Phase1ModelBudget.arm!
    Rag::Phase2RetrieveLimit.arm!

    assert_equal Rag::Phase1ModelBudget, client.send(:armed_validation_budget)
    assert_equal Rag::Phase2RetrieveLimit, service.send(:armed_retrieve_limit)

    budget.arm!
    assert_equal budget, client.send(:armed_validation_budget)
    assert_equal budget, service.send(:armed_retrieve_limit)
    assert_equal Rag::Phase1ModelBudget::CAP, 3
    assert_equal Rag::Phase2RetrieveLimit::LOGICAL_CAP, 1
    assert_equal Rag::Phase2RetrieveLimit::PHYSICAL_PER_LOGICAL, 2
  end

  test "arm keeps an existing ledger" do
    budget = Rag::Phase4WebCheck::Budget
    budget.arm!
    budget.checkpoint!("model")
    budget.arm!
    assert_equal 1, budget.model_attempts
  end

  test "model and logical increments stay inside the caps under threads" do
    budget = Rag::Phase4WebCheck::Budget
    budget.arm!
    logical_ok, logical_blocked = concurrent_calls(6) { budget.begin_logical! }
    assert_equal 2, logical_ok
    assert_equal 4, logical_blocked
    assert_equal 2, budget.logical

    budget.disarm!
    budget.arm!
    model_ok, model_blocked = concurrent_calls(8) { budget.checkpoint!("model") }
    assert_equal 4, model_ok
    assert_equal 4, model_blocked
    assert_equal 4, budget.model_attempts
  end

  test "startup refuses an incomplete process before connect" do
    assert_refused "not_development", rails_env: "production"
    assert_refused "activation_in_dotenv", dotenv: "export PHASE4_WEB_CHECK=1\n"
    assert_refused "activation_absent", env: passing_env.except("PHASE4_WEB_CHECK")
    assert_refused "aws_retry_mode", env: passing_env.except("AWS_RETRY_MODE")
    assert_refused "aws_max_attempts", env: passing_env.merge("AWS_MAX_ATTEMPTS" => "3")
    assert_refused "web_concurrency", env: passing_env.except("WEB_CONCURRENCY")
    assert_refused "web_concurrency", env: passing_env.merge("WEB_CONCURRENCY" => "2")
    assert_refused "solid_queue_in_puma", env: passing_env.merge("SOLID_QUEUE_IN_PUMA" => "1")
    assert_refused "inline_jobs", queue_adapter: "ActiveJob::QueueAdapters::InlineAdapter"
    assert_refused "inline_jobs", queue_adapter: "ActiveJob::QueueAdapters::AsyncAdapter"
    assert_refused "queue_guard", queue_guard_active: true
    assert_refused "invoke_model:legacy_handler", clients: clients_with(:invoke_model, legacy_handler: true)
    assert_refused "retrieve:max_attempts", clients: clients_with(:retrieve, max_attempts: 3)
    assert_refused "converse:retry_limit", clients: clients_with(:converse, retry_limit: 3)
    assert_refused "invoke_model:standard_handler", clients: clients_with(:invoke_model, standard_handler: false)
  end

  test "startup connects once and arms only when the precheck passes" do
    budget = Rag::Phase4WebCheck::Budget
    connected = []
    reason = Rag::Phase4WebCheck.activate!(**gate_inputs(connected))
    assert_nil reason
    assert_equal [ :called ], connected
    assert_predicate budget, :armed?

    failing = Rag::Phase1PinnedTurn.stub_environment.merge("primary_database" => "smart_deal_development")
    budget.disarm!
    connected = []
    reason = Rag::Phase4WebCheck.activate!(**gate_inputs(connected, snapshot: failing))
    assert_equal "environment:primary_database", reason
    assert_equal [ :called ], connected
    assert_not_predicate budget, :armed?
  end

  test "a comment in dotenv is not activation and the real file does not assign it" do
    assert_not Rag::Phase4WebCheck.activation_in_dotenv?("# PHASE4_WEB_CHECK=1\n")
    assert Rag::Phase4WebCheck.activation_in_dotenv?("PHASE4_WEB_CHECK=1\n")
    path = Rails.root.join(".env")
    return unless path.file?

    assert_not Rag::Phase4WebCheck.activation_in_dotenv?(path.read),
           "PHASE4_WEB_CHECK must stay absent from .env"
  end

  test "the exclusive puma file is single process and does not load solid queue" do
    source = Rails.root.join("config/puma_phase4_web_check.rb").read
    assert_match(/^workers 0$/, source)
    assert_no_match(/solid_queue/, source)
    assert_no_match(/WEB_CONCURRENCY/, source)
  end

  test "the initializer arms only when the process activation is present" do
    assert_not_equal "1", ENV.fetch("PHASE4_WEB_CHECK", nil)
    source = Rails.root.join("config/initializers/phase4_web_check.rb").read
    assert_includes source, 'ENV["PHASE4_WEB_CHECK"] == "1"'
    assert_includes source, "Rag::Phase4WebCheck.boot!"
    assert_not_predicate Rag::Phase4WebCheck::Budget, :armed?
  end

  test "observe reads handler classes from the entry list" do
    handlers = Object.new
    handlers.define_singleton_method(:entries) do
      [ Struct.new(:handler_class).new(RetryErrors::Handler) ]
    end
    handlers.define_singleton_method(:map) { raise "handler list each yields classes" }
    config = Struct.new(:max_attempts, :retry_limit, :retry_mode).new(1, 3, "standard")
    client = Object.new
    client.define_singleton_method(:handlers) { handlers }
    client.define_singleton_method(:config) { config }

    view = Rag::Phase4WebCheck.send(:observe, client)

    assert view.standard_handler
    assert_not view.legacy_handler
    assert_equal 1, view.max_attempts
  end

  class RetryErrors
    class Handler; end
    class LegacyHandler; end
  end

  test "the startup script exits before puma when activation or retry config is missing" do
    output, status = run_script(script_env)
    assert_not_predicate status, :success?
    assert_includes output, "activation_absent"

    output, status = run_script(script_env("PHASE4_WEB_CHECK" => "1"))
    assert_not_predicate status, :success?
    assert_includes output, "aws_retry_mode"
    assert_not_includes output, "Puma starting"
  end

  private

  def disarm_validation_budgets
    Rag::Phase4WebCheck::Budget.disarm!
    Rag::Phase1ModelBudget.disarm! if defined?(Rag::Phase1ModelBudget)
    Rag::Phase1QueueGuard.disarm! if defined?(Rag::Phase1QueueGuard)
    Rag::Phase2ModelBudget.disarm! if defined?(Rag::Phase2ModelBudget)
    Rag::Phase2RetrieveLimit.disarm! if defined?(Rag::Phase2RetrieveLimit)
    Rag::Phase3ModelBudget.disarm! if defined?(Rag::Phase3ModelBudget)
    Rag::Phase3RetrieveLimit.disarm! if defined?(Rag::Phase3RetrieveLimit)
  end

  def converse_client(model_calls)
    sdk = Object.new
    sdk.define_singleton_method(:converse) do |*|
      model_calls[:n] += 1
      { "ok" => true }
    end
    client = BedrockClient.allocate
    client.instance_variable_set(:@converse_client, sdk)
    client
  end

  def retrieve_service(&block)
    service = BedrockRagService.allocate
    aws = Object.new
    aws.define_singleton_method(:retrieve) { |*| block.call }
    service.instance_variable_set(:@client, aws)
    service
  end

  def with_five_yields
    original = Bedrock::AuroraColdStartRetry.method(:with_retry)
    Bedrock::AuroraColdStartRetry.define_singleton_method(:with_retry) do |**_, &block|
      5.times { block.call }
    end
    yield
  ensure
    Bedrock::AuroraColdStartRetry.define_singleton_method(:with_retry, original)
  end

  def concurrent_calls(count)
    ok = Queue.new
    blocked = Queue.new
    threads = Array.new(count) do
      Thread.new do
        yield
        ok << 1
      rescue Rag::Phase4WebCheck::Budget::Stop
        blocked << 1
      end
    end
    threads.each(&:join)
    [ ok.size, blocked.size ]
  end

  def passing_env
    {
      "PHASE4_WEB_CHECK" => "1",
      "AWS_RETRY_MODE" => "standard",
      "AWS_MAX_ATTEMPTS" => "1",
      "WEB_CONCURRENCY" => "0"
    }
  end

  def client_view(retry_limit:, **overrides)
    values = {
      max_attempts: 1,
      retry_limit: retry_limit,
      retry_mode: "standard",
      legacy_handler: false,
      standard_handler: true
    }.merge(overrides)
    Rag::Phase4WebCheck::ClientView.new(**values)
  end

  def passing_clients
    {
      invoke_model: client_view(retry_limit: 3),
      retrieve: client_view(retry_limit: 3),
      converse: client_view(retry_limit: 0)
    }
  end

  def clients_with(name, **overrides)
    clients = passing_clients
    current = clients.fetch(name).to_h
    clients[name] = Rag::Phase4WebCheck::ClientView.new(**current.merge(overrides))
    clients
  end

  def gate_inputs(connected, **overrides)
    {
      env: passing_env,
      dotenv: "# PHASE4_WEB_CHECK=1\n",
      rails_env: "development",
      queue_adapter: "ActiveJob::QueueAdapters::SolidQueueAdapter",
      queue_guard_active: false,
      clients: passing_clients,
      snapshot: Rag::Phase1PinnedTurn.stub_environment,
      connector: -> { connected << :called }
    }.merge(overrides)
  end

  def assert_refused(expected, **overrides)
    connected = []
    reason = Rag::Phase4WebCheck.activate!(**gate_inputs(connected, **overrides))
    assert_equal expected, reason
    assert_empty connected
    assert_not_predicate Rag::Phase4WebCheck::Budget, :armed?
  end

  def script_path
    Rails.root.join("script/field_companion/phase4_web_server.rb")
  end

  def script_env(extra = {})
    env = ENV.to_h
    %w[PHASE4_WEB_CHECK AWS_RETRY_MODE AWS_MAX_ATTEMPTS WEB_CONCURRENCY SOLID_QUEUE_IN_PUMA].each do |key|
      env.delete(key)
    end
    env.merge(extra)
  end

  def run_script(env)
    output = +""
    status = nil
    Open3.popen2e(env, Gem.ruby, script_path.to_s) do |stdin, stdout, wait|
      stdin.close
      Timeout.timeout(5) { output = stdout.read.to_s }
      status = wait.value
    rescue Timeout::Error
      Process.kill("TERM", wait.pid)
      flunk "phase4 web script did not exit"
    end
    [ output, status ]
  end
end
