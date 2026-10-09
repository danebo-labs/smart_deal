# frozen_string_literal: true

require "test_helper"

class Rag::Phase1PinnedTurnTest < ActiveSupport::TestCase
  MESSAGE = "Estoy revisando un Elemont MH por un problema de puerta en el nivel 2. Según el plano seleccionado, ¿dónde aparece la seguridad de esa puerta y cómo se relaciona con las demás seguridades?"

  setup do
    @authorization = ENV["PHASE1_PINNED_TURN_AUTHORIZED"]
    @require = ENV["PHASE1_PINNED_TURN_REQUIRE"]
  end

  teardown do
    restore_env("PHASE1_PINNED_TURN_AUTHORIZED", @authorization)
    restore_env("PHASE1_PINNED_TURN_REQUIRE", @require)
    Rag::Phase1ModelBudget.disarm!
    Rag::Phase1QueueGuard.disarm!
  end

  test "refuses a wrong environment and a missing authorization before a session" do
    spy = executor_spy
    document = pinned_document(accounts(:legacy))

    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    wrong = assert_no_difference("ConversationSession.count") do
      Rag::Phase1PinnedTurn.call(
        account: accounts(:legacy),
        user: users(:one),
        document: document,
        message: MESSAGE,
        connections: Rag::Phase1PinnedTurn::EXPECTED_ENVIRONMENT.merge("primary" => "smart_deal_development"),
        executor: spy,
        interpreter_client: quiet_converse,
        enforce_capture_uri: false
      )
    end
    assert_equal "refused", wrong.status
    assert_equal "environment:primary", wrong.reason
    assert_empty spy.calls
    assert_empty spy.retrieve_calls

    ENV.delete("PHASE1_PINNED_TURN_AUTHORIZED")
    missing = assert_no_difference("ConversationSession.count") do
      Rag::Phase1PinnedTurn.call(
        account: accounts(:legacy),
        user: users(:one),
        document: document,
        message: MESSAGE,
        connections: Rag::Phase1PinnedTurn::EXPECTED_ENVIRONMENT,
        executor: spy,
        interpreter_client: quiet_converse,
        enforce_capture_uri: false
      )
    end
    assert_equal "refused", missing.status
    assert_equal "authorization_absent", missing.reason
    assert_empty spy.calls
  end

  test "refuses the capture uri before pinning and keeps the historical budget closed" do
    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    document = pinned_document(accounts(:legacy))
    result = assert_no_difference("ConversationSession.count") do
      Rag::Phase1PinnedTurn.call(
        account: accounts(:legacy),
        user: users(:one),
        document: document,
        message: MESSAGE,
        connections: Rag::Phase1PinnedTurn::EXPECTED_ENVIRONMENT,
        executor: executor_spy,
        interpreter_client: quiet_converse
      )
    end

    assert_equal "refused", result.status
    assert_equal "canonical_uri", result.reason
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    assert_not_equal Rag::Phase1PinnedTurn::CAPTURE_ORIGINAL_SOURCE_URI, document.canonical_uri
  end

  test "pins the selected document and passes only its uris" do
    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    account = accounts(:legacy)
    document = pinned_document(account)
    spy = executor_spy
    result = Rag::Phase1PinnedTurn.call(
      account: account,
      user: users(:one),
      document: document,
      message: MESSAGE,
      connections: Rag::Phase1PinnedTurn::EXPECTED_ENVIRONMENT,
      executor: spy,
      interpreter_client: quiet_converse,
      enforce_capture_uri: false,
      run_id: "test-pin"
    )

    assert_equal "ok", result.status, result.reason
    session = ConversationSession.find(result.session_id)
    assert_equal "phase1:pinned:test-pin", session.identifier
    assert_equal [ document.canonical_uri ], result.uris
    assert_equal [ document.canonical_uri ], session.document_focus_entries.pluck("source_uri")
    assert_equal [ document.canonical_uri ], spy.calls.sole[:entity_s3_uris]
    assert_equal "phase1:#{session.id}:query", spy.calls.sole[:correlation_id]
    assert_empty spy.retrieve_calls

    filter = BedrockRagService.allocate.send(:document_pin_filter, result.uris).to_json
    assert_includes filter, document.canonical_uri
    assert_not_includes filter, "account_id"
    assert_not_includes filter, "manual_corpus"

    turn = result.capture.find { |event| event["kind"] == "phase1_turn" }
    assert_equal session.id, turn["session_id"]
    assert_equal "phase1:#{session.id}", turn["technician_correlation_id"]
    assert_equal "phase1:#{session.id}:query", turn["query_correlation_id"]
    assert_equal "phase1:#{session.id}", turn["correlation_root"]
    if session.live_episode_id.present?
      assert_equal session.live_episode_id, turn["episode_id"]
    end
  end

  test "blocks the fourth model call before the client and does not retry an error" do
    calls = 0
    client = BedrockClient.allocate
    aws = Object.new
    aws.define_singleton_method(:invoke_model) do |*|
      calls += 1
      Struct.new(:body).new(StringIO.new('{"content":[{"text":"ok"}],"usage":{"input_tokens":0,"output_tokens":0}}'))
    end
    client.instance_variable_set(:@client, aws)

    Rag::Phase1ModelBudget.arm!
    3.times do
      Rag::Phase1ModelBudget.checkpoint!("seed")
      Rag::Phase1ModelBudget.record_success!("seed")
    end
    error = assert_raises(Rag::Phase1ModelBudget::Stop) { client.generate_text("cuarta") }
    assert_match(/before the client/, error.message)
    assert_equal 0, calls

    Rag::Phase1ModelBudget.disarm!
    Rag::Phase1ModelBudget.arm!
    aws.define_singleton_method(:invoke_model) { |_params| calls += 1; raise "model down" }
    assert_raises(Rag::Phase1ModelBudget::Stop) { client.generate_text("falla") }
    assert_equal 1, calls
    assert_raises(Rag::Phase1ModelBudget::Stop) { client.generate_text("reintento") }
    assert_equal 1, calls
    assert_equal "error", Rag::Phase1ModelBudget.ledger.find { |row| row["name"] == "generate_text" }["outcome"]
    assert_equal "blocked", Rag::Phase1ModelBudget.ledger.last["outcome"]
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  end

  test "a retrieve stays outside the model cap" do
    Rag::Phase1ModelBudget.arm!
    3.times do
      Rag::Phase1ModelBudget.checkpoint!("seed")
      Rag::Phase1ModelBudget.record_success!("seed")
    end
    service = BedrockRagService.allocate
    calls = 0
    aws = Object.new
    aws.define_singleton_method(:retrieve) { |_params| calls += 1; "chunk" }
    service.instance_variable_set(:@client, aws)

    assert_equal "chunk", service.send(:retrieve_with_retry, {})
    assert_equal 1, calls
    assert_equal 3, Rag::Phase1ModelBudget.attempts
  end

  test "an armed generation error skips the cold-start retry" do
    service = BedrockRagService.allocate
    calls = 0
    aws = Object.new
    aws.define_singleton_method(:retrieve_and_generate) { |_params| calls += 1; raise "generation down" }
    service.instance_variable_set(:@client, aws)
    Rag::Phase1ModelBudget.arm!
    retried = false
    trace = TracePoint.new(:call) do |point|
      retried = true if point.method_id == :with_retry && point.path.end_with?("aurora_cold_start_retry.rb")
    end
    trace.enable
    assert_raises(Rag::Phase1ModelBudget::Stop) { service.send(:retrieve_and_generate_with_retry, {}) }
    assert_raises(Rag::Phase1ModelBudget::Stop) { service.send(:retrieve_and_generate_with_retry, {}) }
    trace.disable

    assert_equal 1, calls
    assert_equal false, retried
    assert_equal "error", Rag::Phase1ModelBudget.ledger.find { |row| row["name"] == "retrieve_and_generate" }["outcome"]
  end

  test "an unexpected job is refused before the queue and tracking stays inline" do
    Rag::Phase1QueueGuard.activate!
    inlined = 0
    queued_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    assert_raises(Rag::Phase1QueueGuard::UnexpectedJob) do
      KbDocumentEnrichmentJob.perform_later
    end
    assert_equal queued_before, ActiveJob::Base.queue_adapter.enqueued_jobs.size
    TrackBedrockQueryJob.singleton_class.alias_method(:phase1_perform_now_original, :perform_now)
    TrackBedrockQueryJob.define_singleton_method(:perform_now) { |*| inlined += 1 }
    TrackBedrockQueryJob.perform_later(model_id: "stub")
    TrackBedrockQueryJob.singleton_class.alias_method(:perform_now, :phase1_perform_now_original)
    assert_equal queued_before, ActiveJob::Base.queue_adapter.enqueued_jobs.size
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  end

  test "the script entry refuses without authorization and does not connect" do
    ENV["PHASE1_PINNED_TURN_REQUIRE"] = "1"
    ENV.delete("PHASE1_PINNED_TURN_AUTHORIZED")
    load Rails.root.join("script/field_companion/phase1_pinned_turn.rb")

    assert_equal 2, phase1_pinned_turn_main
    assert_equal false, Rag::Phase1PinnedTurn.authorized?
  end

  private

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  def pinned_document(account)
    KbDocument.create!(
      account: account,
      s3_key: "uploads/phase1-#{account.id}-#{SecureRandom.hex(4)}.pdf",
      display_name: "Phase 1 stub",
      knowledge_scope: "tenant_private"
    )
  end

  def quiet_converse
    response = Object.new
    response.define_singleton_method(:usage) { nil }
    response.define_singleton_method(:output) { nil }
    client = Object.new
    client.define_singleton_method(:converse) { |_params| response }
    client
  end

  def executor_spy
    Class.new do
      attr_reader :calls, :retrieve_calls

      def initialize
        @calls = []
        @retrieve_calls = []
      end

      def execute(_question, **kwargs)
        @calls << kwargs
        result = Object.new
        result.define_singleton_method(:success?) { true }
        result.define_singleton_method(:answer) { "stub" }
        result.define_singleton_method(:correlation_id) { nil }
        result.define_singleton_method(:pending_question) { nil }
        result
      end

      def retrieve_chunks(*)
        @retrieve_calls << true
        []
      end
    end.new
  end
end
