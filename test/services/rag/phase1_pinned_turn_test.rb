# frozen_string_literal: true

require "test_helper"

class Rag::Phase1PinnedTurnTest < ActiveSupport::TestCase
  MESSAGE = "Estoy revisando un Elemont MH por un problema de puerta en el nivel 2. Según el plano seleccionado, ¿dónde aparece la seguridad de esa puerta y cómo se relaciona con las demás seguridades?"

  setup do
    Rag::Phase1PinnedTurn
    @authorization = ENV["PHASE1_PINNED_TURN_AUTHORIZED"]
    @require = ENV["PHASE1_PINNED_TURN_REQUIRE"]
  end

  teardown do
    restore_env("PHASE1_PINNED_TURN_AUTHORIZED", @authorization)
    restore_env("PHASE1_PINNED_TURN_REQUIRE", @require)
    Rag::Phase1QueueGuard.disarm!
    Rag::Phase1ModelBudget.disarm!
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
        connections: Rag::Phase1PinnedTurn.stub_environment.merge("primary_database" => "smart_deal_development"),
        executor: spy,
        interpreter_client: quiet_converse,
        enforce_capture_uri: false,
        evidence_root: test_evidence_root,
        run_id: "refuse-env"
      )
    end
    assert_equal "refused", wrong.status
    assert_equal "environment:primary_database", wrong.reason
    assert_empty spy.calls
    assert_empty spy.retrieve_calls

    ENV.delete("PHASE1_PINNED_TURN_AUTHORIZED")
    missing = assert_no_difference("ConversationSession.count") do
      Rag::Phase1PinnedTurn.call(
        account: accounts(:legacy),
        user: users(:one),
        document: document,
        message: MESSAGE,
        connections: Rag::Phase1PinnedTurn.stub_environment,
        executor: spy,
        interpreter_client: quiet_converse,
        enforce_capture_uri: false,
        evidence_root: test_evidence_root,
        run_id: "refuse-auth"
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
        connections: Rag::Phase1PinnedTurn.stub_environment,
        executor: executor_spy,
        interpreter_client: quiet_converse,
        evidence_root: test_evidence_root,
        run_id: "refuse-uri"
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
      connections: Rag::Phase1PinnedTurn.stub_environment,
      executor: spy,
      interpreter_client: quiet_converse,
      enforce_capture_uri: false,
      evidence_root: test_evidence_root,
      run_id: "test-pin"
    )

    assert_equal "completed", result.status, result.reason
    assert_equal "pending", JSON.parse(File.read(File.join(result.evidence_path, "result.json")))["documentary_acceptance"]
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

  test "a blocked fourth call keeps the prepared request and does not enter the sdk" do
    assert_blocked_fourth("generate_text") do |calls|
      client = BedrockClient.allocate
      aws = Object.new
      aws.define_singleton_method(:invoke_model) { |*| calls[:n] += 1 }
      client.instance_variable_set(:@client, aws)
      client.generate_text("cuarta")
    end

    assert_blocked_fourth("retrieve_and_generate") do |calls|
      service = BedrockRagService.allocate
      aws = Object.new
      aws.define_singleton_method(:retrieve_and_generate) { |*| calls[:n] += 1 }
      service.instance_variable_set(:@client, aws)
      service.send(:retrieve_and_generate_with_retry, { input: { text: "q" }, max_tokens: 20 })
    end

    assert_blocked_fourth("interpreter") do |calls|
      inner = Object.new
      inner.define_singleton_method(:converse) { |*| calls[:n] += 1 }
      Rag::TurnInterpreter.call(
        turn: "puerta",
        episode: Rag::ActiveEpisode.new,
        viewer_account: nil,
        correlation_id: "phase1:block",
        client: Rag::Phase1PinnedTurn::BudgetedConverse.new(inner)
      )
    end
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

  test "an active guard inlines tracking, rejects reentry and other jobs, then enqueues after disarm" do
    singleton = TrackBedrockQueryJob.singleton_class
    Rag::Phase1QueueGuard.activate!
    inlined = 0
    queued_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    tracking = { model_id: "stub", user_query: "puerta", latency_ms: 1, input_tokens: 1, output_tokens: 1 }

    assert_raises(Rag::Phase1QueueGuard::UnexpectedJob) do
      KbDocumentEnrichmentJob.perform_later
    end
    assert_equal queued_before, ActiveJob::Base.queue_adapter.enqueued_jobs.size

    singleton.alias_method(:phase1_guard_perform_now, :perform_now)
    singleton.define_method(:perform_now) { |*, **| inlined += 1 }
    TrackBedrockQueryJob.perform_later(**tracking)
    assert_equal 1, inlined
    assert_equal queued_before, ActiveJob::Base.queue_adapter.enqueued_jobs.size

    reenter = [ true ]
    singleton.define_method(:perform_now) do |*args, **kwargs, &block|
      inlined += 1
      next unless reenter[0]

      reenter[0] = false
      TrackBedrockQueryJob.perform_later(*args, **kwargs, &block)
    end
    error = assert_raises(Rag::Phase1QueueGuard::UnexpectedJob) do
      TrackBedrockQueryJob.perform_later(**tracking)
    end
    assert_match(/reentrant/, error.message)
    assert_equal 2, inlined
    assert_equal queued_before, ActiveJob::Base.queue_adapter.enqueued_jobs.size

    singleton.alias_method(:perform_now, :phase1_guard_perform_now)
    singleton.remove_method(:phase1_guard_perform_now)
    Rag::Phase1QueueGuard.disarm!
    TrackBedrockQueryJob.perform_later(**tracking)
    assert_equal queued_before + 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  ensure
    if singleton&.method_defined?(:phase1_guard_perform_now)
      singleton.alias_method(:perform_now, :phase1_guard_perform_now)
      singleton.remove_method(:phase1_guard_perform_now)
    end
    Rag::Phase1QueueGuard.disarm!
  end

  test "a stub installed after the guard still receives the enqueue" do
    Rag::Phase1QueueGuard.activate!
    Rag::Phase1QueueGuard.disarm!
    seen = []
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**kwargs| seen << kwargs }
    tracking = { model_id: "stub", input_tokens: 1, output_tokens: 1 }

    TrackBedrockQueryJob.perform_later(**tracking)

    assert_equal [ tracking ], seen
  ensure
    restore_perform_later(TrackBedrockQueryJob)
    Rag::Phase1QueueGuard.disarm!
  end

  test "reinstalling the guarded enqueue does not recurse once the guard is disarmed" do
    Rag::Phase1QueueGuard.activate!
    Rag::Phase1QueueGuard.disarm!
    captured = TrackBedrockQueryJob.method(:perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }
    TrackBedrockQueryJob.define_singleton_method(:perform_later, captured)
    tracking = { model_id: "stub", user_query: "puerta", latency_ms: 1, input_tokens: 1, output_tokens: 1 }
    queued_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size

    TrackBedrockQueryJob.perform_later(**tracking)

    assert_equal queued_before + 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  ensure
    restore_perform_later(TrackBedrockQueryJob)
    Rag::Phase1QueueGuard.disarm!
  end

  test "exports the capture when the turn completes and when it stops" do
    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    root = Rails.root.join("tmp/phase1_pinned_turn_test")
    completed = Rag::Phase1PinnedTurn.call(
      account: accounts(:legacy),
      user: users(:one),
      document: pinned_document(accounts(:legacy)),
      message: MESSAGE,
      connections: Rag::Phase1PinnedTurn.stub_environment,
      executor: executor_spy,
      interpreter_client: quiet_converse,
      enforce_capture_uri: false,
      evidence_root: root,
      run_id: "export-completed"
    )
    assert_equal "completed", completed.status
    assert_exported completed, MESSAGE

    stopped = Rag::Phase1PinnedTurn.call(
      account: accounts(:legacy),
      user: users(:one),
      document: pinned_document(accounts(:legacy)),
      message: MESSAGE,
      connections: Rag::Phase1PinnedTurn.stub_environment,
      executor: executor_spy(stop: true),
      interpreter_client: quiet_converse,
      enforce_capture_uri: false,
      evidence_root: root,
      run_id: "export-stopped"
    )
    assert_equal "stopped", stopped.status
    assert_exported stopped, MESSAGE
    assert_equal "pending", JSON.parse(File.read(File.join(stopped.evidence_path, "result.json")))["documentary_acceptance"]
  end

  test "a failed application result is never reported as completed" do
    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    result = Rag::Phase1PinnedTurn.call(
      account: accounts(:legacy),
      user: users(:one),
      document: pinned_document(accounts(:legacy)),
      message: MESSAGE,
      connections: Rag::Phase1PinnedTurn.stub_environment,
      executor: executor_spy(success: false, error_message: "generation down"),
      interpreter_client: quiet_converse,
      enforce_capture_uri: false,
      evidence_root: test_evidence_root,
      run_id: "export-failed"
    )

    assert_equal "failed", result.status
    assert_includes result.reason, "generation down"
    assert_exported result, MESSAGE
    saved = JSON.parse(File.read(File.join(result.evidence_path, "result.json")))
    assert_equal "failed", saved["status"]
    assert_equal "pending", saved["documentary_acceptance"]
  end

  test "an export error after the files exist is not left as completed" do
    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    singleton = Rag::ValidationCapture.singleton_class
    singleton.alias_method(:phase1_export_capture_original, :export_capture)
    singleton.define_method(:export_capture) { |*| raise "spill down" }
    result = Rag::Phase1PinnedTurn.call(
      account: accounts(:legacy),
      user: users(:one),
      document: pinned_document(accounts(:legacy)),
      message: MESSAGE,
      connections: Rag::Phase1PinnedTurn.stub_environment,
      executor: executor_spy,
      interpreter_client: quiet_converse,
      enforce_capture_uri: false,
      evidence_root: test_evidence_root,
      run_id: "export-spill"
    )

    assert_equal "failed", result.status
    assert_includes result.reason, "evidence_export:RuntimeError"
    assert_includes result.reason, "prior=completed"
    saved = JSON.parse(File.read(File.join(result.evidence_path, "result.json")))
    assert_equal "failed", saved["status"]
    assert_includes saved["reason"], "evidence_export:RuntimeError"
    assert_equal "pending", saved["documentary_acceptance"]
  ensure
    singleton.alias_method(:export_capture, :phase1_export_capture_original) if singleton&.method_defined?(:phase1_export_capture_original)
  end

  test "an evidence write failure does not stay completed" do
    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    file = Tempfile.new("phase1-evidence")
    file.close
    result = Rag::Phase1PinnedTurn.call(
      account: accounts(:legacy),
      user: users(:one),
      document: pinned_document(accounts(:legacy)),
      message: MESSAGE,
      connections: Rag::Phase1PinnedTurn.stub_environment,
      executor: executor_spy,
      interpreter_client: quiet_converse,
      enforce_capture_uri: false,
      evidence_root: file.path,
      run_id: "export-broken"
    )

    assert_equal "failed", result.status
    assert_includes result.reason, "evidence_export"
  end

  test "refuses a loaded bucket that disagrees with the declared bucket before a session" do
    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    spy = executor_spy
    drifted = Rag::Phase1PinnedTurn.stub_environment.merge(
      "kb_bucket_env" => Rag::Phase1PinnedTurn::PROD_BUCKET,
      "kb_bucket_effective" => "smart-deal-dev-kb"
    )
    result = assert_no_difference("ConversationSession.count") do
      Rag::Phase1PinnedTurn.call(
        account: accounts(:legacy),
        user: users(:one),
        document: pinned_document(accounts(:legacy)),
        message: MESSAGE,
        connections: drifted,
        executor: spy,
        interpreter_client: quiet_converse,
        enforce_capture_uri: false,
        evidence_root: test_evidence_root,
        run_id: "refuse-bucket"
      )
    end

    assert_equal "refused", result.status
    assert_equal "environment:kb_bucket_effective", result.reason
    assert_empty spy.calls
    assert_empty spy.retrieve_calls
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  end

  test "the loaded process environment is refused before a session" do
    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    spy = executor_spy
    result = assert_no_difference("ConversationSession.count") do
      Rag::Phase1PinnedTurn.call(
        account: accounts(:legacy),
        user: users(:one),
        document: pinned_document(accounts(:legacy)),
        message: MESSAGE,
        connections: Rag::Phase1PinnedTurn.effective_environment,
        executor: spy,
        interpreter_client: quiet_converse,
        enforce_capture_uri: false,
        evidence_root: test_evidence_root,
        run_id: "refuse-loaded"
      )
    end

    assert_equal "refused", result.status
    assert_match(/\Aenvironment:/, result.reason)
    assert_empty spy.calls
  end

  test "an owner turn exports the interpreter request the stub received" do
    ENV["PHASE1_PINNED_TURN_AUTHORIZED"] = "1"
    previous_mode = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    previous_episode = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    account = accounts(:legacy)
    document = pinned_document(account)
    client = recording_meta_client
    spy = executor_spy
    result = Rag::Phase1PinnedTurn.call(
      account: account,
      user: users(:one),
      document: document,
      message: MESSAGE,
      connections: Rag::Phase1PinnedTurn.stub_environment,
      executor: spy,
      interpreter_client: client,
      enforce_capture_uri: false,
      evidence_root: test_evidence_root,
      run_id: "audit-owner"
    )

    assert_equal "completed", result.status, result.reason
    assert_equal 1, client.calls
    assert client.received.key?(:model_id)
    memory = result.capture.find { |event| event["kind"] == "interpreter_request" }
    assert_equal Rag::ValidationCapture.sanitize(client.received), memory["request"]
    assert_includes memory["message_text"], "work_context"
    assert_includes memory["system"], "You classify one technician turn"
    assert_nil memory["episode_id"]
    assert_equal "phase1:#{result.session_id}", memory["correlation_root"]
    assert_equal "phase1:#{result.session_id}", memory["correlation_id"]
    assert result.capture.none? { |event| %w[retrieve generate_text retrieval_results retrieve_and_generate].include?(event["kind"]) }
    assert_equal result.capture.pluck("sequence"), (1..result.capture.size).to_a
    later = result.capture.find { |event| event["kind"] == "phase1_turn" }
    assert_operator memory["sequence"], :<, later["sequence"]
    assert_equal result.session_id, later["session_id"]
    assert_exported(result, MESSAGE)
    request = JSON.parse(File.read(File.join(result.evidence_path, "capture.json")))["events"].find { |event| event["kind"] == "interpreter_request" }
    assert_includes request["message_text"], "work_context"
    assert_empty spy.retrieve_calls
  ensure
    restore_env("HAIKU_QUERY_ANALYSIS_MODE", previous_mode)
    restore_env("FIELD_COMPANION_EPISODE_ENABLED", previous_episode)
  end

  test "the script entry refuses without authorization and does not connect" do
    previous_root = ENV["PHASE1_PINNED_TURN_EVIDENCE_ROOT"]
    ENV["PHASE1_PINNED_TURN_REQUIRE"] = "1"
    ENV["PHASE1_PINNED_TURN_EVIDENCE_ROOT"] = test_evidence_root.to_s
    ENV.delete("PHASE1_PINNED_TURN_AUTHORIZED")
    load Rails.root.join("script/field_companion/phase1_pinned_turn.rb")

    output = capture_io { assert_equal 2, phase1_pinned_turn_main }.first
    assert_includes output, "tmp/phase1_pinned_turn_test"
    assert_not_includes output, "tmp/phase1_pinned_turn/runs"
    assert_equal false, Rag::Phase1PinnedTurn.authorized?
  ensure
    restore_env("PHASE1_PINNED_TURN_EVIDENCE_ROOT", previous_root)
  end

  private

  def assert_blocked_fourth(operation)
    calls = { n: 0 }
    Rag::Phase1ModelBudget.disarm!
    Rag::Phase1ModelBudget.arm!
    3.times do
      Rag::Phase1ModelBudget.checkpoint!("seed")
      Rag::Phase1ModelBudget.record_success!("seed")
    end
    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.correlation = "phase1:block"
      Rag::ValidationCapture.attempt = 4
      assert_raises(Rag::Phase1ModelBudget::Stop) { yield calls }
    end

    prepared = events.find { |event| event["operation"] == operation && event["result"] == "prepared" }
    blocked = events.find { |event| event["operation"] == operation && event["result"] == "blocked" }
    assert prepared, operation
    assert blocked, operation
    assert_equal "phase1:block", prepared["correlation_id"], operation
    assert_equal "phase1:block", blocked["correlation_id"], operation
    assert_equal "observed", prepared["provenance"], operation
    assert events.none? { |event| event["operation"] == operation && event["result"] == "attempt_started" }, operation
    assert_equal 0, calls[:n], operation
    assert_equal 3, Rag::Phase1ModelBudget.attempts, operation
    if operation == "interpreter"
      assert_equal 1, prepared["attempt"], operation
      assert_equal 1, blocked["attempt"], operation
      assert_includes prepared["message_text"], "puerta"
    else
      assert_equal 4, prepared["attempt"], operation
      assert_equal 4, blocked["attempt"], operation
    end
    assert_equal "cuarta", prepared["prompt"] if operation == "generate_text"
    assert_equal 20, prepared["max_tokens"] if operation == "retrieve_and_generate"
  ensure
    Rag::Phase1ModelBudget.disarm!
  end

  def test_evidence_root
    Rails.root.join("tmp/phase1_pinned_turn_test")
  end

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

  def recording_meta_client
    tool = {
      "move" => "meta",
      "assertions" => [],
      "observations" => [],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
    Object.new.tap do |client|
      calls = 0
      received = nil
      client.define_singleton_method(:calls) { calls }
      client.define_singleton_method(:received) { received }
      client.define_singleton_method(:converse) do |params|
        calls += 1
        received = params
        tool_use = Struct.new(:name, :input).new("turn_perception", tool)
        block = Struct.new(:tool_use).new(tool_use)
        message = Struct.new(:content).new([ block ])
        output = Struct.new(:message).new(message)
        usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
        Struct.new(:output, :usage).new(output, usage)
      end
    end
  end

  def quiet_converse
    response = Object.new
    response.define_singleton_method(:usage) { nil }
    response.define_singleton_method(:output) { nil }
    client = Object.new
    client.define_singleton_method(:converse) { |_params| response }
    client
  end

  def assert_exported(result, message)
    directory = Pathname(result.evidence_path)
    %w[environment.json message.txt turn.json capture.json result.json ledger.json].each do |name|
      assert File.file?(directory.join(name)), name
    end
    assert_equal message, File.read(directory.join("message.txt"))
    turn = JSON.parse(File.read(directory.join("turn.json")))
    assert_equal result.session_id, turn["session_id"]
    assert_equal "phase1:#{result.session_id}", turn["technician_correlation_id"]
    assert_equal "phase1:#{result.session_id}:query", turn["query_correlation_id"]
    capture = JSON.parse(File.read(directory.join("capture.json")))
    assert_equal "danebo.audit.v1", capture["schema_version"]
    assert_equal directory.basename.to_s, capture["run_id"]
    events = capture["events"]
    assert_equal (1..events.size).to_a, events.pluck("sequence")
    assert events.any? { |event| event["kind"] == "phase1_turn" }
    request = events.find { |event| event["kind"] == "interpreter_request" }
    assert_includes request["message_text"], "work_context" if request
    assert events.none? { |event| %w[retrieve generate_text retrieval_results retrieve_and_generate].include?(event["kind"]) }
    assert_not_includes capture.to_s, "AKIA"
    ledger = JSON.parse(File.read(directory.join("ledger.json")))
    assert ledger.key?("attempts")
    assert ledger.dig("cost", "cost_usd").present? || ledger.dig("cost", "cost_usd") == "unavailable"
  end

  test "the harness snapshot records the route flags deploy.yml turns on" do
    previous_structured = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    previous_family = ENV.fetch("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED", nil)
    ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED")
    ENV.delete("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED")

    snapshot = Rag::Phase1PinnedTurn.effective_environment

    assert_equal false, snapshot["structured_evidence_route"]
    assert_equal false, snapshot["family_ambiguity_guard"]
    assert_equal true, snapshot["production_structured_evidence_route"]
    assert_equal true, snapshot["production_family_ambiguity_guard"]
    assert_equal %w[structured_evidence_route family_ambiguity_guard],
                 snapshot["route_flag_differences"].pluck("flag")
  ensure
    restore_env("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", previous_structured)
    restore_env("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED", previous_family)
  end

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end

  def executor_spy(success: true, stop: false, error_message: nil)
    Class.new do
      attr_reader :calls, :retrieve_calls

      define_method(:initialize) do
        @calls = []
        @retrieve_calls = []
      end

      define_method(:execute) do |_question, **kwargs|
        raise Rag::Phase1ModelBudget::Stop, "cap" if stop

        @calls << kwargs
        result = Object.new
        result.define_singleton_method(:success?) { success }
        result.define_singleton_method(:answer) { "stub" }
        result.define_singleton_method(:correlation_id) { nil }
        result.define_singleton_method(:pending_question) { nil }
        result.define_singleton_method(:error_class) { "RuntimeError" }
        result.define_singleton_method(:error_message) { error_message }
        result
      end

      define_method(:retrieve_chunks) do |*|
        @retrieve_calls << true
        []
      end
    end.new
  end
end
