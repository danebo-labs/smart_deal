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

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
