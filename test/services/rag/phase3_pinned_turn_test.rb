# frozen_string_literal: true

require "test_helper"

class Rag::Phase3PinnedTurnTest < ActiveSupport::TestCase
  AURORA = "The Aurora DB instance db-X is resuming after being auto-paused."
  FOLLOW_UP_ANSWER = "Sigo con la etiqueta ya elegida."
  CORRECTION_ANSWER = "La etiqueta que sigo ahora es la que acabas de indicar."
  SUMMARY_ANSWER = "El caso sigue abierto. Falta comprobar el pasaje de la etiqueta vigente."
  INVENTED_ANSWER = "La causa es un contacto. Alimenta la cerradura y la acciona. Mido 0 ohm."
  RESERVED_PHRASE = "terminal de control"

  setup do
    @authorization = ENV["PHASE3_PINNED_TURN_AUTHORIZED"]
    @episode = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    @turn = ENV["FIELD_COMPANION_TURN_ENABLED"]
    @haiku = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    @system_role = ENV["RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"]
    ENV["PHASE3_PINNED_TURN_AUTHORIZED"] = "1"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    ENV["FIELD_COMPANION_TURN_ENABLED"] = "true"
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"] = "1"
  end

  teardown do
    restore_env("PHASE3_PINNED_TURN_AUTHORIZED", @authorization)
    restore_env("FIELD_COMPANION_EPISODE_ENABLED", @episode)
    restore_env("FIELD_COMPANION_TURN_ENABLED", @turn)
    restore_env("HAIKU_QUERY_ANALYSIS_MODE", @haiku)
    restore_env("RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE", @system_role)
    Rag::Phase1QueueGuard.disarm!
    Rag::Phase1ModelBudget.disarm!
    Rag::Phase2ModelBudget.disarm!
    Rag::Phase2RetrieveLimit.disarm!
    Rag::Phase2RetrievedBodyGate.disarm!
    Rag::Phase3ModelBudget.disarm!
    Rag::Phase3RetrieveLimit.disarm!
  end

  test "three turns keep the cloned episode and pin and replace only the chosen label" do
    document = pinned_document(accounts(:legacy))
    source = write_source("continuity-source")
    source_hashes = tree_hashes(source)
    decoy = ConversationSession.create!(
      account: accounts(:legacy), user: users(:one),
      identifier: "phase2:pinned:#{Rag::Phase3PinnedTurn::SOURCE_RUN_ID}",
      channel: "web", expires_at: 30.days.from_now,
      conversation_history: [ { "role" => "user", "content" => "do-not-touch" } ],
      active_episode: {}
    )
    decoy_updated = decoy.updated_at
    executor = counting_executor(answers: [ FOLLOW_UP_ANSWER, CORRECTION_ANSWER, SUMMARY_ANSWER ])
    result = nil
    assert_difference("ConversationSession.count", 1) do
      result = Rag::Phase3PinnedTurn.run(
        account: accounts(:legacy), user: users(:one), document: document,
        snapshot: snapshot, connections: Rag::Phase1PinnedTurn.stub_environment,
        executor: executor, interpreter_client: scripted_interpreter,
        enforce_capture_uri: false, evidence_root: evidence_root, source_root: source,
        run_id: "continuity"
      )
    end

    assert_equal "turns_recorded", result.status
    assert_equal 6, result.attempts
    assert_equal 0, result.retrieve_budget["run_physical"]
    session = ConversationSession.find(result.session_id)
    assert_not_equal decoy.id, session.id
    assert_equal "phase3:pinned:continuity", session.identifier
    decoy.reload
    assert_equal decoy_updated.to_i, decoy.updated_at.to_i
    assert_equal [ { "role" => "user", "content" => "do-not-touch" } ], decoy.conversation_history
    assert_equal source_hashes, tree_hashes(source)
    assert_equal [ document.id ], session.focus_document_ids
    assert session.conversation_history.none? { |message| message.key?("mark") }
    assert_includes session.conversation_history.to_json, RESERVED_PHRASE
    assert_not_includes session.active_episode.to_json, RESERVED_PHRASE

    turn1 = Pathname(result.evidence_path).join("turn_1")
    turn2 = Pathname(result.evidence_path).join("turn_2")
    turn3 = Pathname(result.evidence_path).join("turn_3")
    after1 = JSON.parse(File.read(turn1.join("state_after.json")))
    after2 = JSON.parse(File.read(turn2.join("state_after.json")))
    after3 = JSON.parse(File.read(turn3.join("state_after.json")))
    provenance = JSON.parse(File.read(File.join(result.evidence_path, "provenance.json")))

    assert_equal Rag::Phase3PinnedTurn::SOURCE_EPISODE_ID, after1["live_episode_id"]
    assert_equal after1["live_episode_id"], after2["live_episode_id"]
    assert_equal after1["live_episode_id"], after3["live_episode_id"]
    assert_equal after1["document_focus"], after2["document_focus"]
    assert_equal after1["document_focus"], after3["document_focus"]
    assert_equal [ "Elemont MH", "Chapa nivel 2" ], after1.dig("active_episode", "identifiers").pluck("value")
    assert_equal "user", after1.dig("active_episode", "identifiers", 1, "source")
    assert_equal "phase2:13:t2", after1.dig("active_episode", "identifiers", 1, "correlation_id")
    chosen = after3.dig("active_episode", "identifiers").find { |item| item["value"] == "Chapa nivel 3" }
    assert_equal "user", chosen["source"]
    assert_equal "phase3:#{session.id}:t2", chosen["correlation_id"]
    assert_not_includes after3.dig("active_episode", "identifiers").pluck("value"), "Chapa nivel 2"
    assert_includes after3.dig("active_episode", "identifiers").pluck("value"), "Elemont MH"
    rejected = after3.dig("active_episode", "rejected").find { |item| item["value"] == "Chapa nivel 2" }
    assert_equal "identifier", rejected["slot"]
    assert_equal "Elemont", after3.dig("active_episode", "facts", "manufacturer", "value")
    assert_equal "user", after3.dig("active_episode", "facts", "manufacturer", "source")
    assert_equal Rag::Phase3PinnedTurn::GOAL_TEXT, after3.dig("active_episode", "goal", "text")
    assert_equal [ Rag::Phase3PinnedTurn::GOAL_TEXT ], after3.dig("active_episode", "observations").pluck("text")
    assert_equal SUMMARY_ANSWER, File.binread(turn3.join("answer.txt"))
    assert_not_includes File.binread(turn3.join("answer.txt")), "ohm"
    assert_equal [ 2, 4, 6 ], [ after1, after2, after3 ].map { |state| state.dig("counters", "model_attempts") }
    assert_equal provenance.dig("turn_directory_sha256", "turn_1"), directory_sha(turn1)
    assert_equal provenance.dig("turn_directory_sha256", "turn_2"), directory_sha(turn2)
    turn2_correlation = "phase3:#{session.id}:t2"
    turn3_correlation = "phase3:#{session.id}:t3"
    assert_not_includes File.read(turn1.join("capture.json")), turn2_correlation
    assert_includes File.read(turn2.join("capture.json")), turn2_correlation
    assert_not_includes File.read(turn2.join("capture.json")), turn3_correlation
    assert_includes File.read(turn3.join("capture.json")), turn3_correlation
    assert_equal "pending", JSON.parse(File.read(turn2.join("result.json")))["real_interpreter_correct"]
    assert_equal "not_accepted", provenance["phase3_acceptance"]
    assert_equal "cloned_session", provenance["continuation"]
    assert_equal false, provenance["phase2_calls_repeated"]
    assert_equal Rag::Phase2RetrievedBodyGate::CHUNK_KEY, provenance.dig("inherited_evidence", "key")
    assert_equal Rag::Phase3PinnedTurn::INHERITED_SHA256, provenance.dig("inherited_evidence", "sha256")
    assert_equal false, provenance.dig("inherited_evidence", "retrieved_in_this_run")
    assert_equal "evaluator_simulation", provenance.dig("messages", 0, "mark")
    assert_not Rag::ObservationCorrection.resolve(turn: Rag::Phase3PinnedTurn::CORRECTION).active?
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    assert_equal 188, Rag::Stage2RunBudget::HISTORICAL_CALLS
    assert_equal BigDecimal("0.423114"), Rag::Stage2RunBudget::HISTORICAL_COST_USD
    assert_equal 4, Rag::Phase2ModelBudget::CAP
    assert_not Rag::Phase3ModelBudget.armed?
  end

  test "a summary that invents supply or actuation does not enter the episode" do
    document = pinned_document(accounts(:legacy))
    result = Rag::Phase3PinnedTurn.run(
      account: accounts(:legacy), user: users(:one), document: document,
      snapshot: snapshot, connections: Rag::Phase1PinnedTurn.stub_environment,
      executor: counting_executor(answers: [ FOLLOW_UP_ANSWER, CORRECTION_ANSWER, INVENTED_ANSWER ]),
      interpreter_client: scripted_interpreter, enforce_capture_uri: false,
      evidence_root: evidence_root, run_id: "invented-summary"
    )
    session = ConversationSession.find(result.session_id)
    episode = session.active_episode

    assert_equal "turns_recorded", result.status
    assert_equal INVENTED_ANSWER, File.binread(File.join(result.evidence_path, "turn_3", "answer.txt"))
    assert_not_includes episode.to_json, "ohm"
    assert_not_includes episode.to_json, "cerradura"
    assert_not_includes episode.to_json, "Alimenta"
    assert_not_includes episode.to_json, "causa"
    assert_equal [ "Elemont" ], episode["facts"].values.pluck("value")
    assert_not_includes episode["identifiers"].pluck("value"), "Chapa nivel 2"
    assert_includes episode["rejected"].pluck("value"), "Chapa nivel 2"
  end

  test "an altered retrieved body stops before generation and leaves earlier turns" do
    document = pinned_document(accounts(:legacy))
    source = write_source("gate-source")
    source_hashes = tree_hashes(source)
    calls = { generate: 0 }
    executor = Object.new
    executor.define_singleton_method(:execute) do |*|
      Rag::Phase2RetrievedBodyGate.check!(
        [ { content: "alterado", metadata: { "s3_key" => Rag::Phase2RetrievedBodyGate::CHUNK_KEY } } ]
      )
      calls[:generate] += 1
      raise "generation should not start"
    end
    result = Rag::Phase3PinnedTurn.run(
      account: accounts(:legacy), user: users(:one), document: document,
      snapshot: snapshot, connections: Rag::Phase1PinnedTurn.stub_environment,
      executor: executor, interpreter_client: scripted_interpreter,
      enforce_capture_uri: false, evidence_root: evidence_root, source_root: source,
      run_id: "gate-stop"
    )

    assert_equal "stopped", result.status
    assert_equal 0, calls[:generate]
    assert_equal source_hashes, tree_hashes(source)
    assert File.file?(File.join(result.evidence_path, "turn_1", "capture.json"))
    assert_not File.directory?(File.join(result.evidence_path, "turn_2"))
    capture = JSON.parse(File.read(File.join(result.evidence_path, "turn_1", "capture.json")))
    assert capture["events"].any? { |event| event["kind"] == "inherited_evidence" && event["remote"] == false }
    assert capture["events"].any? { |event| event["kind"] == "retrieved_body" && event["result"] == "blocked" }
  end

  test "the seventh model attempt and the seventh retrieve do not leave" do
    calls = { invoke: 0, converse: 0, retrieve: 0 }
    client = BedrockClient.allocate
    aws = Object.new
    aws.define_singleton_method(:invoke_model) do |*|
      calls[:invoke] += 1
      Struct.new(:body).new(StringIO.new('{"content":[{"text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}'))
    end
    client.instance_variable_set(:@client, aws)
    Rag::Phase3ModelBudget.arm!
    6.times { client.generate_text("turno") }
    assert_raises(Rag::Phase3ModelBudget::Stop) { client.generate_text("septimo") }
    assert_equal 6, calls[:invoke]
    Rag::Phase3ModelBudget.disarm!

    inner = Object.new
    inner.define_singleton_method(:converse) do |*|
      calls[:converse] += 1
      "ok"
    end
    wrapper = Rag::Phase3PinnedTurn::BudgetedConverse.new(inner)
    Rag::Phase3ModelBudget.arm!
    6.times { wrapper.converse({}) }
    assert_raises(Rag::Phase3ModelBudget::Stop) { wrapper.converse({}) }
    assert_equal 6, calls[:converse]
    Rag::Phase3ModelBudget.disarm!

    Rag::Phase3ModelBudget.disarm!
    Rag::Phase2ModelBudget.arm!
    calls[:invoke] = 0
    4.times { client.generate_text("fase2") }
    assert_raises(Rag::Phase2ModelBudget::Stop) { client.generate_text("quinta") }
    assert_equal 4, calls[:invoke]
    assert_equal 4, Rag::Phase2ModelBudget::CAP
    Rag::Phase2ModelBudget.disarm!

    service = retrieve_service do
      calls[:retrieve] += 1
      raise aurora_error
    end
    without_sleep do
      Rag::Phase3RetrieveLimit.arm!
      3.times do
        Rag::Phase3RetrieveLimit.begin_turn!
        assert_raises(Rag::Phase3RetrieveLimit::Stop) { service.send(:retrieve_with_retry, {}) }
      end
      assert_equal 6, calls[:retrieve]
      assert_equal 6, Rag::Phase3RetrieveLimit.run_physical
      Rag::Phase3RetrieveLimit.begin_turn!
      assert_raises(Rag::Phase3RetrieveLimit::Stop) { service.send(:retrieve_with_retry, {}) }
      assert_equal 6, calls[:retrieve]
    end
  end

  test "phase 2 pause cannot continue session 13 and the script stays closed" do
    pause_path = evidence_root.join("closed-pause", "pause.json")
    FileUtils.mkdir_p(pause_path.dirname)
    File.write(pause_path, JSON.pretty_generate("status" => "second_turn_recorded", "session_id" => 13))
    before = Digest::SHA256.file(pause_path).hexdigest
    refused = Rag::Phase2PinnedTurn.continue(pause_path: pause_path, accept_candidate: true)
    assert_equal "refused", refused.status
    assert_equal "budget_closed", refused.reason
    assert_equal before, Digest::SHA256.file(pause_path).hexdigest

    ENV.delete("PHASE3_PINNED_TURN_AUTHORIZED")
    assert_no_difference("ConversationSession.count") do
      missing = Rag::Phase3PinnedTurn.run(
        account: accounts(:legacy), user: users(:one), document: pinned_document(accounts(:legacy)),
        snapshot: snapshot, connections: Rag::Phase1PinnedTurn.stub_environment,
        enforce_capture_uri: false, evidence_root: evidence_root, run_id: "unauthorized"
      )
      assert_equal "authorization_absent", missing.reason
    end

    ENV["PHASE3_PINNED_TURN_AUTHORIZED"] = "1"
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "off"
    assert_no_difference("ConversationSession.count") do
      closed = Rag::Phase3PinnedTurn.run(
        account: accounts(:legacy), user: users(:one), document: pinned_document(accounts(:legacy)),
        snapshot: snapshot, connections: Rag::Phase1PinnedTurn.stub_environment,
        enforce_capture_uri: false, evidence_root: evidence_root, run_id: "owner-off"
      )
      assert_equal "owner_mode_absent", closed.reason
    end

    previous = ENV["PHASE3_PINNED_TURN_REQUIRE"]
    argv = ARGV.dup
    ENV["PHASE3_PINNED_TURN_REQUIRE"] = "1"
    ENV.delete("PHASE3_PINNED_TURN_AUTHORIZED")
    load Rails.root.join("script/field_companion/phase3_pinned_turn.rb")
    ARGV.replace([])
    assert_equal 2, phase3_pinned_turn_main
  ensure
    ARGV.replace(argv) if argv
    restore_env("PHASE3_PINNED_TURN_REQUIRE", previous)
  end

  test "evidence is refused when it would write inside the phase 2 run" do
    source = write_source("overlap-source")
    before = tree_hashes(source)
    refused = Rag::Phase3PinnedTurn.run(
      account: accounts(:legacy), user: users(:one), document: pinned_document(accounts(:legacy)),
      snapshot: snapshot, connections: Rag::Phase1PinnedTurn.stub_environment,
      enforce_capture_uri: false, evidence_root: source, source_root: source, run_id: "overlap"
    )

    assert_equal "refused", refused.status
    assert_equal "evidence_overlaps_source", refused.reason
    assert_equal before, tree_hashes(source)
    loaded = Rag::Phase3PinnedTurn.load_source(source)
    assert_equal 13, loaded["source_session_id"]
    assert_equal Rag::Phase3PinnedTurn::SOURCE_EPISODE_ID, loaded["source_episode_id"]
    assert_equal before, tree_hashes(source)
  end

  private

  def evidence_root
    Rails.root.join("tmp/phase3_pinned_turn_test")
  end

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end

  def pinned_document(account)
    KbDocument.create!(
      account: account,
      s3_key: "uploads/phase3-#{account.id}-#{SecureRandom.hex(4)}.pdf",
      display_name: "Phase 3 stub",
      knowledge_scope: "tenant_private"
    )
  end

  def snapshot(assistant: "Chapa nivel 2 queda descrita como #{RESERVED_PHRASE} en la respuesta anterior.")
    {
      "source_run_id" => Rag::Phase3PinnedTurn::SOURCE_RUN_ID,
      "source_session_id" => Rag::Phase3PinnedTurn::SOURCE_SESSION_ID,
      "source_episode_id" => Rag::Phase3PinnedTurn::SOURCE_EPISODE_ID,
      "source_document_id" => Rag::Phase3PinnedTurn::DOCUMENT_ID,
      "source_uri" => Rag::Phase1PinnedTurn::CAPTURE_ORIGINAL_SOURCE_URI,
      "pause_status" => "second_turn_recorded",
      "active_episode" => {
        "v" => 1,
        "goal" => {
          "text" => Rag::Phase3PinnedTurn::GOAL_TEXT,
          "truncated" => false,
          "correlation_id" => "phase2:13:t1"
        },
        "facts" => {
          "manufacturer" => {
            "at" => "2026-10-12T14:54:50-03:00",
            "value" => "Elemont",
            "source" => "user",
            "status" => "known",
            "correlation_id" => "phase2:13:t1"
          }
        },
        "status" => "active",
        "conflicts" => [],
        "opened_at" => "2026-10-12T14:54:50-03:00",
        "opened_by" => "phase2:13:t1",
        "episode_id" => Rag::Phase3PinnedTurn::SOURCE_EPISODE_ID,
        "updated_at" => "2026-10-12T14:55:55-03:00",
        "identifiers" => [
          { "value" => "Elemont MH", "source" => "user", "correlation_id" => "phase2:13:t1" },
          { "value" => "Chapa nivel 2", "source" => "user", "correlation_id" => "phase2:13:t2" }
        ],
        "observations" => [
          { "text" => Rag::Phase3PinnedTurn::GOAL_TEXT, "correlation_id" => "phase2:13:t1" }
        ]
      },
      "messages" => [
        { "role" => "user", "text" => Rag::Phase2PinnedTurn::FIRST_MESSAGE, "correlation_id" => "phase2:13:t1" },
        { "role" => "assistant", "text" => "¿A qué equipo o elemento te refieres?", "correlation_id" => "phase2:13:t1:query" },
        { "role" => "user", "text" => Rag::Phase2PinnedTurn::CANDIDATE_REPLY, "correlation_id" => "phase2:13:t2" },
        { "role" => "assistant", "text" => assistant, "correlation_id" => Rag::Phase3PinnedTurn::SOURCE_QUERY_CORRELATION }
      ]
    }
  end

  def write_source(name)
    directory = evidence_root.join(name)
    FileUtils.rm_rf(directory)
    FileUtils.mkdir_p(directory.join("turn_2"))
    data = snapshot
    File.write(directory.join("pause.json"), JSON.pretty_generate(
      "status" => data["pause_status"],
      "session_id" => data["source_session_id"],
      "run_id" => data["source_run_id"],
      "first_message" => data.dig("messages", 0, "text"),
      "published_answer" => data.dig("messages", 1, "text"),
      "candidate_reply" => data.dig("messages", 2, "text"),
      "second_published_answer" => data.dig("messages", 3, "text")
    ))
    File.write(directory.join("turn_2", "state_after.json"), JSON.pretty_generate(
      "active_episode" => data["active_episode"],
      "document_focus" => [
        {
          "kb_document_id" => data["source_document_id"],
          "source_uri" => data["source_uri"]
        }
      ]
    ))
    directory
  end

  def counting_executor(answers:)
    queue = answers.dup
    client = BedrockClient.allocate
    aws = Object.new
    aws.define_singleton_method(:invoke_model) do |*|
      Struct.new(:body).new(StringIO.new('{"content":[{"text":"ok"}],"usage":{"input_tokens":3,"output_tokens":2}}'))
    end
    client.instance_variable_set(:@client, aws)
    executor = Object.new
    executor.define_singleton_method(:execute) do |*|
      client.generate_text("generacion")
      text = queue.shift
      result = Object.new
      result.define_singleton_method(:success?) { true }
      result.define_singleton_method(:answer) { text }
      result.define_singleton_method(:pending_question) { nil }
      result
    end
    executor
  end

  def scripted_interpreter
    responses = [
      tool("follow_up"),
      tool("correct", assertions: [
        { "span" => "Chapa nivel 2", "act" => "negate" },
        { "span" => "Chapa nivel 3", "act" => "assert" }
      ]),
      tool("follow_up")
    ]
    client = Object.new
    client.define_singleton_method(:converse) do |_params|
      tool_use = Struct.new(:name, :input).new("turn_perception", responses.shift)
      block = Struct.new(:tool_use).new(tool_use)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(4, 2)
      Struct.new(:output, :usage).new(output, usage)
    end
    client
  end

  def tool(move, assertions: [])
    {
      "move" => move,
      "assertions" => assertions,
      "observations" => [],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def tree_hashes(directory)
    directory = Pathname(directory)
    directory.glob("**/*").select(&:file?).sort.map { |path|
      [ path.relative_path_from(directory).to_s, Digest::SHA256.file(path).hexdigest ]
    }
  end

  def directory_sha(directory)
    digest = Digest::SHA256.new
    Pathname(directory).glob("**/*").select(&:file?).sort.each do |path|
      digest << path.relative_path_from(directory).to_s
      digest << Digest::SHA256.file(path).hexdigest
    end
    digest.hexdigest
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
    original = Bedrock::AuroraColdStartRetry.method(:sleep_for)
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for) { |_seconds| nil }
    yield
  ensure
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for, original) if original
  end
end
