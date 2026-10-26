# frozen_string_literal: true

require "test_helper"

class Rag::WebTurnCaptureExportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  NORMAL = "La puerta no cierra."
  META_TURN = "No sé cómo identificar si está activada la entrada #21 ni cómo saber si hay un contacto cerrado entre #21 y #23. ¿Qué información necesitas de mí para orientar el caso?"
  QUESTION = "¿Está activada la entrada de re-apertura (#21)?"
  REPLY = "Indicaste que no puedes distinguirlo. #{'dato ' * 500}"

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @previous_run = ENV["RAG_VALIDATION_CAPTURE_RUN"]
    @previous_accounts = ENV["RAG_VALIDATION_CAPTURE_ACCOUNT_IDS"]
    @run_id = "webcap#{SecureRandom.hex(4)}"
    ENV["RAG_VALIDATION_CAPTURE_RUN"] = @run_id
    ENV.delete("RAG_VALIDATION_CAPTURE_ACCOUNT_IDS")
    Rag::LocalPassLedger.reset_local_process!
  end

  teardown do
    @previous_run.nil? ? ENV.delete("RAG_VALIDATION_CAPTURE_RUN") : ENV["RAG_VALIDATION_CAPTURE_RUN"] = @previous_run
    if @previous_accounts.nil?
      ENV.delete("RAG_VALIDATION_CAPTURE_ACCOUNT_IDS")
    else
      ENV["RAG_VALIDATION_CAPTURE_ACCOUNT_IDS"] = @previous_accounts
    end
    FileUtils.rm_rf(Rails.root.join(Rag::WebRequestCapture::ROOT, @run_id))
    Thread.current[:rag_validation_capture] = nil
    Rag::LocalPassLedger.reset_local_process!
  end

  test "a local pass still captures and a production list stays on the named account" do
    assert Rag::WebRequestCapture.enabled?

    Rag::LocalPassLedger.instance_variable_set(:@local_process, false)
    assert_not Rag::WebRequestCapture.enabled?
    assert_not Rag::WebRequestCapture.enabled_for(1)

    ENV["RAG_VALIDATION_CAPTURE_ACCOUNT_IDS"] = "1"
    assert Rag::WebRequestCapture.enabled_for(1)
    assert_not Rag::WebRequestCapture.enabled_for(2)
    assert_not Rag::WebRequestCapture.enabled_for(nil)

    Rag::WebRequestCapture.wrap(controller: controller_for(account_id: 2, question: "ajena")) do
      Rag::ValidationCapture.record("user_message", "original" => "ajena", "sent" => "ajena", "transform" => "none")
    end
    assert_empty capture_paths

    Rag::WebRequestCapture.wrap(controller: controller_for(account_id: 1, question: "cuenta uno")) do
      Rag::ValidationCapture.record("user_message", "original" => "cuenta uno", "sent" => "cuenta uno", "transform" => "none")
    end

    document = JSON.parse(File.read(capture_paths.sole))
    assert_equal "cuenta uno", document["events"].first["question"]
    assert_equal "account", document["events"].first["capture_scope"]
    assert_equal 0o600, File.stat(capture_paths.sole).mode & 0o777
  end

  test "a normal turn and a meta turn export episode, proposal, reasons, and the full antecedent" do
    normal_id = "query:normal-#{SecureRandom.hex(4)}"
    meta_id = "query:meta-#{SecureRandom.hex(4)}"

    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      with_owner_flags do
        Rag::WebRequestCapture.wrap(controller: controller_for(account_id: @account.id, question: NORMAL)) do
          session = web_session
          session.record_user_turn!(NORMAL, user_id: @user.id, correlation_id: normal_id, interpreter_client: ReportStub.new)
          record_plan(session, normal_id)
          session.record_assistant_turn!(
            "La puerta no cierra sigue pendiente.",
            user_id: @user.id,
            correlation_id: normal_id,
            expected_episode_id: session.live_episode_id,
            prompt_reply: "La puerta no cierra sigue pendiente."
          )
        end

        Rag::WebRequestCapture.wrap(controller: controller_for(account_id: @account.id, question: META_TURN)) do
          session = seeded_session
          session.record_user_turn!(META_TURN, user_id: @user.id, correlation_id: meta_id, interpreter_client: MetaStub.new)
          record_plan(session, meta_id)
          session.record_assistant_turn!(
            REPLY,
            user_id: @user.id,
            correlation_id: meta_id,
            expected_episode_id: session.live_episode_id,
            prompt_reply: REPLY
          )
        end
      end
    end

    index_path = Rails.root.join("tmp", "validation_capture_index_#{@run_id}.json")
    document = Rag::ValidationCaptureIndex.build(Rails.root.join(Rag::WebRequestCapture::ROOT, @run_id))
    File.write(index_path, JSON.generate(document))

    assert_equal "complete", document["status"]
    normal = document["turns"].find { |turn| turn["correlation_id"] == normal_id }
    meta = document["turns"].find { |turn| turn["correlation_id"] == meta_id }
    assert normal
    assert meta
    [ normal, meta ].each do |turn|
      assert_equal "complete", turn["status"]
      assert_equal @account.id, turn["account_id"]
      assert_equal @user.id, turn["user_id"]
      assert turn["episode_id"].present?
      Rag::ValidationCaptureIndex::COMPONENTS.each do |name|
        assert_equal "present", turn.dig("components", name), name
      end
    end

    meta_events = events_for(meta["path"])
    raw = meta_events.find { |event| event["kind"] == "interpreter_raw" }
    applied = meta_events.find { |event| event["kind"] == "perception_applied" }
    delta = meta_events.find { |event| event["kind"] == "episode_delta" }
    plan = meta_events.find { |event| event["kind"] == "companion_plan" }
    history = meta_events.find { |event| event["kind"] == "assistant_history" }

    assert_equal "meta", raw.dig("tool_input", "move")
    assert_equal "meta_incompatible", applied["invalid_reason"]
    assert delta["episode_before"].is_a?(Hash)
    assert delta["episode_after"].is_a?(Hash)
    assert_equal "fixture-not-haiku", plan.dig("tool_input", "mark")
    assert plan.dig("check", "rejections").any? { |row| row["reason"].present? }
    assert_equal "stored", history["result"]
    assert history.key?("prompt_reply")
    body = Rails.root.join(Rag::WebRequestCapture::ROOT, @run_id, File.dirname(meta["path"]), history.dig("prompt_reply", "path"))
    assert_equal REPLY, File.read(body)
    assert_equal true, history.dig("prompt_reply", "summary_truncated")
    assert_equal false, history.dig("prompt_reply", "truncated")
    assert_includes meta["truncated_fields"].pluck("body_truncated"), false
  ensure
    FileUtils.rm_f(index_path) if defined?(index_path) && index_path
  end

  test "a rejection count without reasons stays uncaptured" do
    dir = Rails.root.join("tmp", "capture_count_only_#{SecureRandom.hex(4)}")
    request = dir.join("request")
    FileUtils.mkdir_p(request)
    File.write(request.join("capture.json"), JSON.generate(
      "events" => [
        { "kind" => "companion_plan", "correlation_id" => "query:count", "usable" => true, "rejections" => 5 }
      ]
    ))

    document = Rag::ValidationCaptureIndex.build(dir)
    turn = document["turns"].sole

    assert_equal "partial", document["status"]
    assert_equal "uncaptured", turn.dig("components", "checker_reasons")
    assert_equal "uncaptured", turn.dig("components", "companion_plan")
  ensure
    FileUtils.rm_rf(dir) if defined?(dir) && dir
  end

  private

  def with_owner_flags
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") { yield }
      end
    end
  end

  def record_plan(_session, correlation_id)
    composed = Rag::CompanionPlan::Composed.new(
      text: "Texto de ensayo local.",
      check: checker_result,
      input: { "mark" => "fixture-not-haiku", "question" => QUESTION },
      stop_reason: "tool_use",
      pending: nil
    )
    Rag::ValidationCapture.with_turn(correlation_id) do
      BedrockRagService.allocate.send(
        :record_companion_plan,
        composed,
        { "input_tokens" => 3, "output_tokens" => 1 }
      )
    end
  end

  def checker_result
    Rag::CompanionPlanCheck::Result.new(
      links: [],
      steps: [],
      question: nil,
      rejections: [ { "part" => "question", "value" => QUESTION, "reason" => "unknown_limit" } ],
      associations: [],
      confirmed_items: {},
      question_targets: [],
      limits: [],
      omissions: [],
      question_scope: nil
    )
  end

  def events_for(relative)
    path = Rails.root.join(Rag::WebRequestCapture::ROOT, @run_id, relative)
    JSON.parse(File.read(path)).fetch("events")
  end

  def capture_paths
    Dir[Rails.root.join(Rag::WebRequestCapture::ROOT, @run_id, "*", "capture.json").to_s].sort
  end

  def controller_for(account_id:, question:)
    user_id = @user.id
    request = Struct.new(:request_id).new(SecureRandom.uuid)
    params = ActionController::Parameters.new("question" => question)
    controller = Object.new
    controller.define_singleton_method(:request) { request }
    controller.define_singleton_method(:params) { params }
    controller.define_singleton_method(:controller_path) { "rag" }
    controller.define_singleton_method(:action_name) { "ask" }
    controller.define_singleton_method(:current_user) { Struct.new(:id).new(user_id) }
    controller.define_singleton_method(:current_account) { Struct.new(:id).new(account_id) }
    controller
  end

  def seeded_session
    now = Time.current
    episode = Rag::ActiveEpisode.open(correlation_id: "query:seed", now: now)
    episode.assign_goal!("La puerta se reabre sola", correlation_id: "query:seed")
    web_session.tap { |session| session.update!(active_episode: episode.to_h) }
  end

  def web_session
    ConversationSession.create!(
      identifier: "web:capture:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: @user,
      account: @account
    )
  end

  class ReportStub
    def converse(_params)
      tool = Struct.new(:name, :input).new("turn_perception", {
        "move" => "report",
        "assertions" => [],
        "observations" => [ "la puerta no cierra" ],
        "pending_resolution" => nil,
        "clarification_target" => nil
      })
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage, :stop_reason).new(output, usage, "tool_use")
    end
  end

  class MetaStub
    def converse(_params)
      tool = Struct.new(:name, :input).new("turn_perception", {
        "move" => "meta",
        "assertions" => [],
        "observations" => [],
        "pending_resolution" => nil,
        "clarification_target" => nil
      })
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage, :stop_reason).new(output, usage, "tool_use")
    end
  end
end
