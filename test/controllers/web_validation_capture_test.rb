# frozen_string_literal: true

require "test_helper"

class WebValidationCaptureTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  ENV_KEYS = %w[
    RAG_VALIDATION_CAPTURE_RUN
    RAG_LOCAL_PASS_GUARD
    RAG_LOCAL_PASS_CALL_CAP
    RAG_LOCAL_PASS_COST_CAP_USD
    AWS_MAX_ATTEMPTS
  ].freeze

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @user.update!(account: @account)
    @previous = ENV_KEYS.index_with { |key| ENV[key] }
    @run_id = "webreq#{SecureRandom.hex(4)}"
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
  end

  teardown do
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
    FileUtils.rm_rf(Rails.root.join(Rag::WebRequestCapture::ROOT, @run_id))
    Thread.current[:rag_validation_capture] = nil
  end

  test "the browser request captures its own events and the next request does not inherit them" do
    ENV["RAG_VALIDATION_CAPTURE_RUN"] = @run_id
    assert Rag::WebRequestCapture.enabled?
    sign_in @user
    probe = {}

    with_marker("respuesta del request A", probe) do
      post rag_ask_url, params: { question: "mensaje exacto A" }, as: :json
    end
    assert_response :success
    assert_equal "respuesta del request A", response.parsed_body["answer"]
    assert_equal false, probe[:other_active]
    assert_nil Thread.current[:rag_validation_capture]

    first = capture_for("mensaje exacto A")
    assert_equal "mensaje exacto A", first["events"].first["question"]
    assert_includes answers(first), "respuesta del request A"
    assert_not_includes answers(first), "respuesta de otro hilo"
    assert_equal @user.id, first["events"].first["user_id"]

    with_marker("respuesta del request B", {}) do
      post rag_ask_url, params: { question: "mensaje exacto B" }, as: :json
    end
    assert_response :success
    second = capture_for("mensaje exacto B")
    assert_equal [ "respuesta del request B" ], answers(second)
    assert_not_includes answers(second), "respuesta del request A"
    assert_not_includes answers(first), "respuesta del request B"
  end

  test "a request without the run id does not open the capture" do
    ENV.delete("RAG_VALIDATION_CAPTURE_RUN")
    sign_in @user
    active = nil
    with_mock_orchestrator(marker_orchestrator("sin captura") { active = Rag::ValidationCapture.active? }) do
      post rag_ask_url, params: { question: "mensaje sin captura" }, as: :json
    end

    assert_response :success
    assert_equal false, active
    assert_empty capture_paths
  end

  test "the second model call is refused by the local cap and is not sent" do
    ENV["RAG_VALIDATION_CAPTURE_RUN"] = @run_id
    ENV["RAG_LOCAL_PASS_GUARD"] = "1"
    ENV["RAG_LOCAL_PASS_CALL_CAP"] = "1"
    ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = "1"
    ENV["AWS_MAX_ATTEMPTS"] = "1"
    assert Rag::LocalPassLedger.armed?
    sign_in @user
    calls = 0
    orchestrator = Object.new
    orchestrator.define_singleton_method(:execute) do
      Rag::LocalPassLedger.protect!(
        operation: "generate_text",
        model_id: BedrockClient::QUERY_MODEL_ID,
        input_tokens: 1_000,
        output_tokens: 100
      ) { calls += 1 }
      { answer: "primera respuesta", citations: [] }
    end

    with_mock_orchestrator(orchestrator) do
      post rag_ask_url, params: { question: "primera pregunta" }, as: :json
    end
    assert_response :success
    assert_equal "primera respuesta", response.parsed_body["answer"]
    assert_equal 1, calls

    with_mock_orchestrator(orchestrator) do
      post rag_ask_url, params: { question: "segunda pregunta" }, as: :json
    end
    assert_response :service_unavailable
    assert_equal "local_pass_budget", response.parsed_body["code"]
    assert_equal 1, calls
    assert_equal 1, Rag::LocalPassLedger.snapshot["blocked"]
  end

  private

  def with_marker(answer, probe)
    with_mock_orchestrator(marker_orchestrator(answer, probe)) { yield }
  end

  def marker_orchestrator(answer, probe = {}, &probe_hook)
    orchestrator = Object.new
    orchestrator.define_singleton_method(:execute) do
      probe_hook.call if probe_hook
      Rag::ValidationCapture.record(
        "published_answer",
        "stage" => "publish",
        "result" => "published",
        "answer" => answer
      )
      Thread.new do
        probe[:other_active] = Rag::ValidationCapture.active?
        Rag::ValidationCapture.record(
          "published_answer",
          "stage" => "publish",
          "result" => "published",
          "answer" => "respuesta de otro hilo"
        )
      end.join
      { answer: answer, citations: [] }
    end
    orchestrator
  end

  def with_mock_orchestrator(mock)
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_args, **_kwargs| mock }
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def capture_paths
    Dir[Rails.root.join(Rag::WebRequestCapture::ROOT, @run_id, "*", "capture.json").to_s].sort
  end

  def capture_for(question)
    found = capture_paths.map { |path| JSON.parse(File.read(path)) }.find { |document|
      document["events"].first["question"] == question
    }
    assert found, "missing capture for #{question}"
    found
  end

  def answers(document)
    document["events"].filter_map { |event| event["answer"] if event["kind"] == "published_answer" }
  end
end
