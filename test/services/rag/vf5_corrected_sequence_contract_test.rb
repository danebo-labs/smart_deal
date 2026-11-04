# frozen_string_literal: true

require "test_helper"

# Script choice only. The answer contract is the product default, and this
# file does not call retrieval, planning, or a paid interpreter.
class Vf5CorrectedSequenceContractTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  T1 = "Estoy con un Fermator VF5+. Después de un corte de alimentación, al volver la corriente la puerta abrió muy despacio. ¿Por dónde empiezo?"

  setup do
    @script = ENV["VF5_SCRIPT"]
    @require_env = ENV["VF5_CORRECTED_SEQUENCE_REQUIRE"]
    @mode = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    @episode_flag = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["VF5_CORRECTED_SEQUENCE_REQUIRE"] = "1"
    ENV.delete("VF5_SCRIPT")
    %w[TURNS VF5_APERTURA_TURNS].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
    load Rails.root.join("script/field_companion/vf5_corrected_sequence.rb")
    @user = users(:one)
    @account = accounts(:legacy)
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
  end

  teardown do
    restore_env("VF5_SCRIPT", @script)
    restore_env("VF5_CORRECTED_SEQUENCE_REQUIRE", @require_env)
    restore_env("HAIKU_QUERY_ANALYSIS_MODE", @mode)
    restore_env("FIELD_COMPANION_EPISODE_ENABLED", @episode_flag)
  end

  test "the script choice leaves the product contract alone" do
    runner = Rails.root.join("script/field_companion/vf5_corrected_sequence.rb").read
    turn = runner[/def vf5_sequence_turn\(.*?^  end/m]

    assert_equal TURNS, vf5_sequence_turns
    assert_equal 3, TURNS.size
    ENV["VF5_SCRIPT"] = "apertura_lenta"
    assert_equal VF5_APERTURA_TURNS, vf5_sequence_turns
    assert_equal T1, VF5_APERTURA_TURNS.first
    ENV["VF5_SCRIPT"] = "corrected"
    assert_equal TURNS, vf5_sequence_turns
    assert_not_includes turn, "answer_contract"
    assert_not_includes runner, "VF5_ANSWER_CONTRACT"
    assert_not_includes runner, "call_cap: 48"
    assert_not_includes runner, "48 - snap"
    assert_includes turn, "prompt_reply: result.history_answer"
  end

  test "a companion turn stores the history answer as the next prompt reply" do
    session = ConversationSession.create!(
      identifier: "web:vf5-prompt-reply-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: @user,
      account: @account,
      active_episode: {},
      conversation_history: []
    )
    history = "La puerta abrió despacio tras el corte."
    shown = "#{history} [1]"
    host = Object.new
    host.define_singleton_method(:execute) do |*_args, **_kwargs|
      RagQueryConcern::RagResult.new(
        success?: true,
        answer: shown,
        history_answer: history,
        correlation_id: "query:vf5-reply-#{SecureRandom.hex(2)}",
        pending_question: nil
      )
    end
    original = Rag::TurnInterpreter.method(:call)
    Rag::TurnInterpreter.define_singleton_method(:call) do |**_kwargs|
      Rag::TurnInterpreter::Result.new(
        perception: nil, fallback: true, status: "empty", latency_ms: 0,
        input_tokens: 0, output_tokens: 0, model_id: nil,
        error_class: nil, error_reason: nil, stage: "extract"
      )
    end

    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      row = vf5_sequence_turn(host, session, @user, T1, 1, "vf5-prompt-reply")
      assert_equal "returned", row["status"]
    end

    session.reload
    stored = session.conversation_history.reverse.find { |item| item["role"] == "assistant" }
    prior = SessionContextBuilder.companion_prior_answer(session)

    assert_equal history, stored["prompt_reply"]
    assert_includes prior, history
    assert_includes prior, "Conclusión previa de Danebo"
  ensure
    Rag::TurnInterpreter.define_singleton_method(:call) { |*args, **kwargs| original.call(*args, **kwargs) } if original
  end

  test "apertura lenta records eight calls to 174 only while the ledger is at 166" do
    dir = Dir.mktmpdir("vf5-cap")
    path = File.join(dir, "spend.json")
    keys = %w[RAG_LOCAL_PASS_GUARD RAG_LOCAL_PASS_CALL_CAP RAG_LOCAL_PASS_COST_CAP_USD AWS_MAX_ATTEMPTS]
    previous = keys.index_with { |key| ENV[key] }
    keys.each { |key| ENV.delete(key) }
    write_spend(path, attempts: 166, call_cap: 166)
    ENV["VF5_SCRIPT"] = "apertura_lenta"
    spend = vf5_sequence_spend(path)

    assert_equal 0, vf5_sequence_remaining_calls(spend)
    assert_not vf5_arm_sequence_ledger!(spend)
    assert_nil ENV["RAG_LOCAL_PASS_GUARD"]

    vf5_sequence_admit_apertura!(spend)
    granted = spend.snapshot
    unit = Rag::LocalPassLedger.price(BedrockClient::QUERY_MODEL_ID, 40_000, 3_000)

    assert_equal 174, granted.dig("authorization", "call_cap")
    assert_equal "0.750000", granted.dig("authorization", "cost_usd")
    assert_equal "4.0", granted["cost_cap_usd"]
    assert_equal 8, vf5_sequence_remaining_calls(spend)
    assert_equal "kept", granted["entries"].first["marker"]
    assert_equal 2, granted["entries"].size
    execution = granted["executions"].find { |row| row["id"] == "vf5-apertura-lenta-20261103" }
    assert_equal 8, execution["calls"]
    assert_equal 166, execution["after_attempt"]
    assert_equal format("%.6f", unit * 8), execution["cost_usd"]
    assert_equal 2, granted["executions"].find { |row| row["id"] == "f3-scope-reply-20261023" }["calls"]

    ENV["AWS_MAX_ATTEMPTS"] = "1"
    assert vf5_arm_sequence_ledger!(spend)
    assert_equal "8", ENV["RAG_LOCAL_PASS_CALL_CAP"]
    assert_not vf5_sequence_local_databases?

    ENV.delete("VF5_SCRIPT")
    write_spend(path, attempts: 166, call_cap: 166)
    untouched = vf5_sequence_spend(path)
    vf5_sequence_admit_apertura!(untouched)
    assert_equal 166, untouched.snapshot.dig("authorization", "call_cap")

    ENV["VF5_SCRIPT"] = "apertura_lenta"
    write_spend(path, attempts: 167, call_cap: 166)
    late = vf5_sequence_spend(path)
    vf5_sequence_admit_apertura!(late)
    assert_equal 166, late.snapshot.dig("authorization", "call_cap")
    assert_equal 2, late.snapshot["entries"].size
  ensure
    keys&.each { |key| previous[key].nil? ? ENV.delete(key) : ENV[key] = previous[key] }
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  test "this turn's answer report is not the previous turn and not the written row by itself" do
    session = ConversationSession.create!(
      identifier: "web:vf5-report-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: @user,
      account: @account,
      active_episode: {},
      conversation_history: []
    )
    first_id = "query:vf5-report-a"
    second_id = "query:vf5-report-b"
    client = interpreter
    first = nil
    second = nil
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      first = Rag::ValidationCapture.capture do
        session.record_user_turn!(
          VF5_APERTURA_TURNS.first,
          user_id: @user.id,
          correlation_id: first_id,
          locale: :es,
          interpreter_client: client
        )
      end
      second = Rag::ValidationCapture.capture do
        session.record_user_turn!(
          VF5_APERTURA_TURNS.last,
          user_id: @user.id,
          correlation_id: second_id,
          locale: :es,
          interpreter_client: client
        )
      end
    end
    memory = first.select { |event| event["kind"] == "answer_report" && event["stage"] == "memory" }
    persisted = first.select { |event| event["kind"] == "answer_report" && event["stage"] == "persisted" }
    reloaded = Array(session.reload.active_episode["replies"]).pluck("id")

    assert_equal 1, memory.size
    assert_equal first_id, memory.first["correlation_id"]
    assert_equal false, memory.first["persisted"]
    assert_equal "in_memory", memory.first["result"]
    assert_equal 1, persisted.size
    assert_equal first_id, persisted.first["correlation_id"]
    assert_equal reloaded, persisted.first["persisted_reply_ids"]
    assert_equal persisted.first["stored"].all? { |id| reloaded.include?(id) }, persisted.first["persisted"]
    assert second.none? { |event| event["kind"] == "answer_report" && event["correlation_id"] == first_id }
    assert_equal second_id, second.find { |event| event["kind"] == "answer_report" && event["stage"] == "memory" }["correlation_id"]
  end

  test "either script still opens through the application default" do
    [ nil, "apertura_lenta" ].each do |script|
      restore_env("VF5_SCRIPT", script)
      session = ConversationSession.create!(
        identifier: "web:vf5-default-#{SecureRandom.hex(4)}",
        channel: "web",
        expires_at: 1.hour.from_now,
        user: @user,
        account: @account,
        active_episode: {},
        conversation_history: []
      )
      client = interpreter
      events = nil
      assert_no_enqueued_jobs only: TrackBedrockQueryJob do
        events = Rag::ValidationCapture.capture do
          session.record_user_turn!(
            vf5_sequence_turns.first,
            user_id: @user.id,
            correlation_id: "query:vf5-#{SecureRandom.hex(2)}",
            locale: :es,
            interpreter_client: client
          )
        end
      end
      prepared = events.find { |event| event["kind"] == "answer_contract" }
      requested = events.find { |event| event["kind"] == "interpreter_request" }
      stored = session.reload.active_episode

      assert_equal 1, client.payloads.size
      assert_equal 1, prepared["qc"]
      assert_operator prepared["sequence"], :<, requested["sequence"]
      assert_equal 1, stored["qc"]
    end
  end

  private

  def interpreter
    input = {
      "move" => "report",
      "assertions" => [],
      "observations" => [ "La puerta abrió despacio." ],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
    payloads = []
    client = Struct.new(:payloads).new(payloads)
    client.define_singleton_method(:converse) do |params|
      payloads << params
      tool = Struct.new(:name, :input).new(Rag::TurnInterpreter::TOOL_NAME, input)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage).new(output, usage)
    end
    client
  end

  def write_spend(path, attempts:, call_cap:)
    File.write(path, JSON.generate(
      "call_cap" => call_cap,
      "cost_cap_usd" => "4.000000",
      "attempts" => attempts,
      "blocked" => 0,
      "priced" => attempts,
      "seq" => attempts,
      "committed" => "1.565982",
      "unknown" => "0.102140",
      "open" => {},
      "entries" => [
        { "id" => 1, "status" => "settled", "marker" => "kept", "actual_usd" => "0.010000" },
        { "id" => attempts, "status" => "settled", "actual_usd" => "0.007000" }
      ],
      "authorization" => {
        "id" => "f2f3-joint-after-134",
        "after_attempt" => 134,
        "cost_usd" => "0.750000",
        "call_cap" => call_cap
      },
      "executions" => [ {
        "id" => "f3-scope-reply-20261023",
        "after_attempt" => 164,
        "cost_usd" => "0.100000",
        "calls" => 2
      } ]
    ))
  end

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
