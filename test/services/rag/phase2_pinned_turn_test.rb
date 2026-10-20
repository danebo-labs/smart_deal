# frozen_string_literal: true

require "test_helper"

class Rag::Phase2PinnedTurnTest < ActiveSupport::TestCase
  ANSWER = "N" * 400
  AURORA = "The Aurora DB instance db-X is resuming after being auto-paused."

  setup do
    Rag::Phase1PinnedTurn
    Rag::Phase2PinnedTurn
    @authorization = ENV["PHASE2_PINNED_TURN_AUTHORIZED"]
  end

  teardown do
    restore_env("PHASE2_PINNED_TURN_AUTHORIZED", @authorization)
    Rag::Phase1QueueGuard.disarm!
    Rag::Phase1ModelBudget.disarm!
    Rag::Phase2ModelBudget.disarm!
    Rag::Phase2RetrieveLimit.disarm!
    Rag::Phase2RetrievedBodyGate.disarm!
  end

  test "both turns keep the same session and the same pin" do
    ENV["PHASE2_PINNED_TURN_AUTHORIZED"] = "1"
    document = pinned_document(accounts(:legacy))
    executor = counting_executor
    interpreter = quiet_converse
    first = nil
    assert_difference("ConversationSession.count", 1) do
      first = Rag::Phase2PinnedTurn.start(
        account: accounts(:legacy), user: users(:one), document: document,
        connections: Rag::Phase1PinnedTurn.stub_environment, executor: executor,
        interpreter_client: interpreter, enforce_capture_uri: false,
        evidence_root: evidence_root, run_id: "same-session"
      )
    end

    assert_equal "awaiting_decision", first.status
    assert_equal ANSWER, first.answer
    assert_equal interpreter.calls + executor.aws_calls, first.attempts
    session = ConversationSession.find(first.session_id)
    assert_equal "phase2:pinned:same-session", session.identifier
    assert_equal [ document.id ], session.focus_document_ids
    assert_equal [ Rag::Phase2PinnedTurn::FIRST_MESSAGE ], session.conversation_history.filter_map { |message|
      message["content"] if message["role"] == "user"
    }
    assistant = session.conversation_history.find { |message| message["role"] == "assistant" }
    assert_equal ANSWER, assistant["content"]
    assert session.conversation_history.none? { |message| message.key?("mark") }
    pause = JSON.parse(File.read(first.pause_path))
    assert_equal true, pause["evaluator_simulation"]
    assert_equal ANSWER, pause["published_answer"]
    assert_equal "evaluator_simulation", pause.dig("messages", 0, "mark")
    saved = JSON.parse(File.read(File.join(first.evidence_path, "turn_1", "result.json")))
    assert_equal true, saved["evaluator_simulation"]
    assert_equal "pending", saved["documentary_acceptance"]

    second = nil
    assert_no_difference("ConversationSession.count") do
      second = Rag::Phase2PinnedTurn.continue(
        pause_path: first.pause_path, accept_candidate: true, executor: executor,
        interpreter_client: interpreter
      )
    end

    assert_equal "second_turn_recorded", second.status
    assert_equal first.session_id, second.session_id
    assert_equal interpreter.calls + executor.aws_calls, second.attempts
    assert_operator second.attempts, :>, first.attempts
    session.reload
    assert_equal [ document.id ], session.focus_document_ids
    assert_equal [ Rag::Phase2PinnedTurn::FIRST_MESSAGE, Rag::Phase2PinnedTurn::CANDIDATE_REPLY ],
                 session.conversation_history.filter_map { |message| message["content"] if message["role"] == "user" }
    continued = JSON.parse(File.read(second.pause_path))
    assert_equal ANSWER, continued["published_answer"]
    assert_equal true, continued["candidate_sent"]
    assert_equal "evaluator_simulation", continued.dig("messages", 1, "mark")
    assert_equal 3, Rag::Phase1ModelBudget::CAP
    assert_not Rag::Phase1ModelBudget.armed?
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  end

  test "stopping after the first turn does not spend the remainder" do
    ENV["PHASE2_PINNED_TURN_AUTHORIZED"] = "1"
    document = pinned_document(accounts(:legacy))
    executor = counting_executor
    first = Rag::Phase2PinnedTurn.start(
      account: accounts(:legacy), user: users(:one), document: document,
      connections: Rag::Phase1PinnedTurn.stub_environment, executor: executor,
      interpreter_client: quiet_converse, enforce_capture_uri: false,
      evidence_root: evidence_root, run_id: "withhold"
    )
    spent = first.attempts
    calls = executor.aws_calls

    withheld = nil
    assert_no_difference("ConversationSession.count") do
      withheld = Rag::Phase2PinnedTurn.continue(pause_path: first.pause_path, accept_candidate: false)
    end

    assert_equal "withheld", withheld.status
    assert_equal spent, withheld.attempts
    assert_equal calls, executor.aws_calls
    assert_equal ANSWER, JSON.parse(File.read(first.pause_path))["published_answer"]
    session = ConversationSession.find(first.session_id)
    assert_equal [ Rag::Phase2PinnedTurn::FIRST_MESSAGE ], session.conversation_history.filter_map { |message|
      message["content"] if message["role"] == "user"
    }

    refused = Rag::Phase2PinnedTurn.continue(
      pause_path: first.pause_path, accept_candidate: true, executor: executor
    )
    assert_equal "refused", refused.status
    assert_equal "budget_closed", refused.reason
    assert_equal spent, refused.attempts
    assert_equal calls, executor.aws_calls
    absent = Rag::Phase2PinnedTurn.continue(pause_path: first.pause_path, accept_candidate: nil)
    assert_equal "decision_absent", absent.reason
    assert_equal calls, executor.aws_calls
  end

  test "the fifth model attempt does not leave" do
    calls = { invoke: 0, converse: 0 }
    client = BedrockClient.allocate
    aws = Object.new
    aws.define_singleton_method(:invoke_model) do |*|
      calls[:invoke] += 1
      Struct.new(:body).new(StringIO.new('{"content":[{"text":"ok"}],"usage":{"input_tokens":0,"output_tokens":0}}'))
    end
    client.instance_variable_set(:@client, aws)
    inner = Object.new
    inner.define_singleton_method(:converse) do |*|
      calls[:converse] += 1
      "ok"
    end
    wrapper = Rag::Phase2PinnedTurn::BudgetedConverse.new(inner)

    Rag::Phase2ModelBudget.arm!
    2.times { wrapper.converse({}) }
    2.times { client.generate_text("turno") }
    assert_equal 4, Rag::Phase2ModelBudget.attempts
    error = assert_raises(Rag::Phase2ModelBudget::Stop) { client.generate_text("quinto") }
    assert_match(/before the client/, error.message)
    assert_equal 2, calls[:invoke]
    assert_raises(Rag::Phase2ModelBudget::Stop) { wrapper.converse({}) }
    assert_equal 2, calls[:converse]

    Rag::Phase2ModelBudget.disarm!
    Rag::Phase2ModelBudget.arm!
    calls[:invoke] = 0
    aws.define_singleton_method(:invoke_model) do |*|
      calls[:invoke] += 1
      raise "model down"
    end
    assert_raises(Rag::Phase2ModelBudget::Stop) { client.generate_text("falla") }
    assert_raises(Rag::Phase2ModelBudget::Stop) { client.generate_text("reintento") }
    assert_equal 1, calls[:invoke]
  end

  test "phase 1 still blocks the fourth call when phase 2 is disarmed" do
    Rag::Phase2ModelBudget.disarm!
    calls = 0
    client = BedrockClient.allocate
    aws = Object.new
    aws.define_singleton_method(:invoke_model) { |*| calls += 1 }
    client.instance_variable_set(:@client, aws)
    Rag::Phase1ModelBudget.arm!
    3.times do
      Rag::Phase1ModelBudget.checkpoint!("seed")
      Rag::Phase1ModelBudget.record_success!("seed")
    end

    assert_raises(Rag::Phase1ModelBudget::Stop) { client.generate_text("cuarta") }
    assert_equal 0, calls
    assert_equal 3, Rag::Phase1ModelBudget::CAP
    assert_equal 4, Rag::Phase2ModelBudget::CAP
    assert_equal [ 15, 30, 45 ], Bedrock::AuroraColdStartRetry::RETRY_DELAYS
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  end

  test "a third physical request of the same retrieve does not leave" do
    calls = []
    service = retrieve_service { calls << true; raise aurora_error }
    without_sleep do |slept|
      Rag::Phase2RetrieveLimit.arm!
      Rag::Phase2RetrieveLimit.begin_turn!
      assert_raises(Rag::Phase2RetrieveLimit::Stop) { service.send(:retrieve_with_retry, {}) }
      assert_equal 2, calls.size
      assert_equal [ 15, 30 ], slept
      assert_equal [ 15, 30, 45 ], Bedrock::AuroraColdStartRetry::RETRY_DELAYS
    end
  end

  test "a second logical retrieve in the same turn does not leave" do
    calls = []
    service = retrieve_service { calls << true; "chunk" }
    Rag::Phase2RetrieveLimit.arm!
    Rag::Phase2RetrieveLimit.begin_turn!
    assert_equal "chunk", service.send(:retrieve_with_retry, {})
    assert_raises(Rag::Phase2RetrieveLimit::Stop) { service.send(:retrieve_with_retry, {}) }
    assert_equal 1, calls.size
  end

  test "errors other than aurora are not retried" do
    calls = []
    service = retrieve_service do
      calls << true
      raise Aws::BedrockAgentRuntime::Errors::ServiceError.new(nil, "access denied")
    end
    without_sleep do |slept|
      Rag::Phase2RetrieveLimit.arm!
      Rag::Phase2RetrieveLimit.begin_turn!
      assert_raises(Aws::BedrockAgentRuntime::Errors::ServiceError) { service.send(:retrieve_with_retry, {}) }
      assert_equal 1, calls.size
      assert_empty slept
    end
  end

  test "a disarmed phase 2 limit leaves the shared aurora retry unchanged" do
    calls = []
    service = retrieve_service { calls << true; raise aurora_error }
    without_sleep do |slept|
      Rag::Phase2RetrieveLimit.disarm!
      assert_raises(Aws::BedrockAgentRuntime::Errors::ServiceError) { service.send(:retrieve_with_retry, {}) }
      assert_equal 4, calls.size
      assert_equal [ 15, 30, 45 ], slept
    end
  end

  test "the run stops before a fifth physical retrieve" do
    calls = []
    service = retrieve_service { calls << true; "chunk" }
    Rag::Phase2RetrieveLimit.arm!
    4.times do
      Rag::Phase2RetrieveLimit.begin_turn!
      service.send(:retrieve_with_retry, {})
    end
    assert_equal 4, calls.size
    Rag::Phase2RetrieveLimit.begin_turn!
    assert_raises(Rag::Phase2RetrieveLimit::Stop) { service.send(:retrieve_with_retry, {}) }
    assert_equal 4, calls.size
    assert_equal 4, Rag::Phase2RetrieveLimit.run_physical
  end

  test "continuation restores the retrieve count" do
    calls = []
    service = retrieve_service { calls << true; "chunk" }
    Rag::Phase2RetrieveLimit.arm!
    Rag::Phase2RetrieveLimit.begin_turn!
    service.send(:retrieve_with_retry, {})
    saved = Rag::Phase2RetrieveLimit.export
    Rag::Phase2RetrieveLimit.disarm!
    Rag::Phase2RetrieveLimit.restore!(saved)
    Rag::Phase2RetrieveLimit.begin_turn!
    assert_equal 1, Rag::Phase2RetrieveLimit.run_physical
    service.send(:retrieve_with_retry, {})
    assert_equal 2, calls.size
    assert_equal 2, Rag::Phase2RetrieveLimit.run_physical
  end

  test "an unexpected enqueue is captured and refused" do
    ENV["PHASE2_PINNED_TURN_AUTHORIZED"] = "1"
    document = pinned_document(accounts(:legacy))
    queued_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    executor = Object.new
    executor.define_singleton_method(:execute) { |*| KbDocumentEnrichmentJob.perform_later }
    result = Rag::Phase2PinnedTurn.start(
      account: accounts(:legacy), user: users(:one), document: document,
      connections: Rag::Phase1PinnedTurn.stub_environment, executor: executor,
      interpreter_client: quiet_converse, enforce_capture_uri: false,
      evidence_root: evidence_root, run_id: "queue-refusal"
    )

    assert_equal "stopped", result.status
    assert_match(/refused enqueue/, result.reason)
    refusal = result.capture.find { |event| event["kind"] == "queue_refusal" }
    assert_equal "KbDocumentEnrichmentJob", refusal["job"]
    assert_equal "refused", refusal["result"]
    assert_equal queued_before, ActiveJob::Base.queue_adapter.enqueued_jobs.size
    saved = JSON.parse(File.read(File.join(result.evidence_path, "turn_1", "capture.json")))
    assert saved["events"].any? { |event| event["kind"] == "queue_refusal" }
  end

  test "the second turn leaves the first turn files and hashes intact" do
    ENV["PHASE2_PINNED_TURN_AUTHORIZED"] = "1"
    document = pinned_document(accounts(:legacy))
    first_answer = "turno-1-#{'A' * 2400}"
    second_answer = "turno-2-#{'B' * 2400}"
    executor = counting_executor(answers: [ first_answer, second_answer ])
    first = Rag::Phase2PinnedTurn.start(
      account: accounts(:legacy), user: users(:one), document: document,
      connections: Rag::Phase1PinnedTurn.stub_environment, executor: executor,
      interpreter_client: quiet_converse, enforce_capture_uri: false,
      evidence_root: evidence_root, run_id: "turn-files"
    )
    turn1 = Pathname(first.evidence_path).join("turn_1")
    before_hashes = tree_hashes(turn1)
    first_bodies = referenced_bodies(turn1)

    second = Rag::Phase2PinnedTurn.continue(
      pause_path: first.pause_path, accept_candidate: true, executor: executor,
      interpreter_client: quiet_converse
    )
    turn2 = Pathname(second.evidence_path).join("turn_2")
    second_bodies = referenced_bodies(turn2)
    before = JSON.parse(File.read(turn2.join("state_before.json")))
    after = JSON.parse(File.read(turn2.join("state_after.json")))
    first_after = JSON.parse(File.read(turn1.join("state_after.json")))

    assert_equal before_hashes, tree_hashes(turn1)
    assert first_bodies.any?
    assert second_bodies.any?
    assert_empty(first_bodies.pluck("sha256") & second_bodies.pluck("sha256"))
    assert_equal first_answer, File.binread(turn1.join("answer.txt"))
    assert_equal second_answer, File.binread(turn2.join("answer.txt"))
    assert_equal [ first_answer ], body_texts(turn1, first_bodies)
    assert_equal [ second_answer ], body_texts(turn2, second_bodies)
    %w[session_id active_episode live_episode_id document_focus pending_question counters].each do |key|
      assert_same_observed first_after[key], before[key], key
    end
    assert_same_observed before["session_id"], after["session_id"], "session_id"
    assert_same_observed before["document_focus"], after["document_focus"], "document_focus"
    assert_operator after.dig("counters", "model_attempts"), :>, before.dig("counters", "model_attempts")
    pause = JSON.parse(File.read(File.join(first.evidence_path, "pause.json")))
    assert_equal after.dig("counters", "model_attempts"), pause.dig("model_budget", "attempts")
    assert pause.key?("retrieve_budget")
    assert_not_includes File.read(turn1.join("capture.json")), ":t2"
    assert_includes File.read(turn2.join("capture.json")), ":t2"
  end

  test "the continue script stops before a call when the decision is absent" do
    previous = ENV["PHASE2_PINNED_TURN_REQUIRE"]
    argv = ARGV.dup
    answer = ENV["PHASE2_CANDIDATE_ANSWERS"]
    ENV["PHASE2_PINNED_TURN_REQUIRE"] = "1"
    ENV.delete("PHASE2_CANDIDATE_ANSWERS")
    load Rails.root.join("script/field_companion/phase2_pinned_turn.rb")
    ARGV.replace([ "continue" ])

    assert_equal 2, phase2_pinned_turn_main
  ensure
    ARGV.replace(argv) if argv
    restore_env("PHASE2_CANDIDATE_ANSWERS", answer)
    restore_env("PHASE2_PINNED_TURN_REQUIRE", previous)
  end

  private

  def evidence_root
    Rails.root.join("tmp/phase2_pinned_turn_test")
  end

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end

  def pinned_document(account)
    KbDocument.create!(
      account: account,
      s3_key: "uploads/phase2-#{account.id}-#{SecureRandom.hex(4)}.pdf",
      display_name: "Phase 2 stub",
      knowledge_scope: "tenant_private"
    )
  end

  def counting_executor(answer: ANSWER, answers: nil)
    calls = { aws: 0 }
    queue = answers&.dup
    client = BedrockClient.allocate
    aws = Object.new
    aws.define_singleton_method(:invoke_model) do |*|
      calls[:aws] += 1
      Struct.new(:body).new(StringIO.new('{"content":[{"text":"ok"}],"usage":{"input_tokens":0,"output_tokens":0}}'))
    end
    client.instance_variable_set(:@client, aws)
    executor = Object.new
    executor.define_singleton_method(:aws_calls) { calls[:aws] }
    executor.define_singleton_method(:execute) do |_question, **|
      client.generate_text("generacion")
      text = queue ? queue.shift : answer
      result = Object.new
      result.define_singleton_method(:success?) { true }
      result.define_singleton_method(:answer) { text }
      result.define_singleton_method(:pending_question) { nil }
      result
    end
    executor
  end

  def tree_hashes(directory)
    directory = Pathname(directory)
    directory.glob("**/*").select(&:file?).sort.map { |path|
      [ path.relative_path_from(directory).to_s, Digest::SHA256.file(path).hexdigest ]
    }
  end

  def referenced_bodies(turn_directory)
    capture = JSON.parse(File.read(Pathname(turn_directory).join("capture.json")))
    refs = []
    walk = lambda do |node|
      case node
      when Hash
        refs << node if node["evidence"] == "external"
        node.each_value { |value| walk.call(value) }
      when Array
        node.each { |value| walk.call(value) }
      end
    end
    walk.call(capture)
    refs
  end

  def assert_same_observed(expected, actual, label)
    if expected.nil?
      assert_nil actual, label
    else
      assert_equal expected, actual, label
    end
  end

  def body_texts(turn_directory, refs)
    refs.map { |ref| File.binread(Pathname(turn_directory).join(ref["path"])) }
  end

  def quiet_converse
    calls = { n: 0 }
    response = Object.new
    response.define_singleton_method(:usage) { nil }
    response.define_singleton_method(:output) { nil }
    client = Object.new
    client.define_singleton_method(:calls) { calls[:n] }
    client.define_singleton_method(:converse) do |_params|
      calls[:n] += 1
      response
    end
    client
  end

  def retrieve_service(&block)
    service = BedrockRagService.allocate
    aws = Object.new
    aws.define_singleton_method(:retrieve) { |*| block.call }
    service.instance_variable_set(:@client, aws)
    service
  end

  def aurora_error
    Aws::BedrockAgentRuntime::Errors::ServiceError.new(nil, AURORA)
  end

  def without_sleep
    slept = []
    original = Bedrock::AuroraColdStartRetry.method(:sleep_for)
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for) { |seconds| slept << seconds }
    yield slept
  ensure
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for, original) if original
  end
end
