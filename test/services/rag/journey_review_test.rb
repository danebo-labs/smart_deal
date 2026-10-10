# frozen_string_literal: true

require "test_helper"

class Rag::JourneyReviewTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  TURN = "Estoy revisando un Elemont MH por un problema de puerta en el nivel 2. Según el plano seleccionado, ¿dónde aparece la seguridad de esa puerta y cómo se relaciona con las demás seguridades?"
  SYMPTOM = "problema de puerta en el nivel 2"
  BRAKE_GOAL = "ajustar frenos"
  DOOR_EPISODE = "ep_door_level_2"
  DOOR_GOAL = "investigar el problema de puerta en el nivel 2"
  DOOR_OBSERVATION = "la hoja de la puerta del nivel 2 queda entreabierta"
  DOOR_PROCEDURE = { "name" => "seguridad_puerta_nivel_2" }.freeze
  ELEMONT_UID = "dcc8e046-037d-48a6-8913-1992aed28507"
  ELEMONT_KEY = "bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf"

  CASES = [
    {
      key: "bedrock_meta",
      run_id: "20261009T221211Z",
      source: "tmp/phase1_pinned_turn/repeat_capture/20261009T221211Z/capture.json",
      source_sha256: "4e1a93205d80167134d8fedc6510a33d55f67d809bffd559792d521a51045b53",
      fixture: "bedrock_meta.json",
      kind: :capture,
      historical: "not_accepted",
      unconfirmed: true
    },
    {
      key: "haiku45_original",
      run_id: "probe-20261010T022130Z-f3074741",
      source: "tmp/interpreter_anthropic_evidence/probe-20261010T022130Z-f3074741/runs/probe-20261010T022130Z-f3074741/phase1/claude-haiku-4-5-20251001/original/tool_input.json",
      source_sha256: "2fe0a6f7521ba0dd1883a8b5e59b4273407aafa7fc419eb64089d00db736dc50",
      judgment_path: "tmp/interpreter_anthropic_evidence/probe-20261010T022130Z-f3074741/runs/probe-20261010T022130Z-f3074741/phase1/claude-haiku-4-5-20251001/original/judgment.json",
      judgment_sha256: "08aadbd99e247f8363b04984328aaed91ddd7843d60e8cbc6bacf9e8bcf19153",
      fixture: "haiku45_original.json",
      kind: :tool,
      historical: "pass",
      historical_reason: "allowed_move"
    },
    {
      key: "haiku55_original",
      run_id: "probe-20261010T030043Z-98220bd5",
      source: "tmp/interpreter_anthropic_evidence/probe-20261010T030043Z-98220bd5/runs/probe-20261010T030043Z-98220bd5/phase1/claude-haiku-5-5/original/tool_input.json",
      source_sha256: "e032355893ce7a6c8bded0d4cba542d966aa4119857b2573dcdc1189f541d4f8",
      judgment_path: "tmp/interpreter_anthropic_evidence/probe-20261010T030043Z-98220bd5/runs/probe-20261010T030043Z-98220bd5/phase1/claude-haiku-5-5/original/judgment.json",
      judgment_sha256: "57b311717a00840b82af14a5a1f4f2da6440209ad2e04eb28864a8f8ddf83a17",
      fixture: "haiku55_original.json",
      kind: :tool,
      historical: "fail",
      historical_reason: "forbidden_move"
    },
    {
      key: "haiku45_opus",
      run_id: "probe-20261010T030043Z-98220bd5",
      source: "tmp/interpreter_anthropic_evidence/probe-20261010T030043Z-98220bd5/runs/probe-20261010T030043Z-98220bd5/phase1/claude-haiku-4-5-20251001/opus_2026_10_09/tool_input.json",
      source_sha256: "67e3cdff8bf06d471d5e97aa4aa27300a5ce6b03c54f0ec2e90b90abe5597ce4",
      judgment_path: "tmp/interpreter_anthropic_evidence/probe-20261010T030043Z-98220bd5/runs/probe-20261010T030043Z-98220bd5/phase1/claude-haiku-4-5-20251001/opus_2026_10_09/judgment.json",
      judgment_sha256: "197a1dcc07c186b962aa38eb51179c05764b987e8ec85f7925d1029308b78322",
      fixture: "haiku45_opus.json",
      kind: :tool,
      historical: "pass",
      historical_reason: "allowed_move"
    },
    {
      key: "haiku55_opus",
      run_id: "probe-20261010T030043Z-98220bd5",
      source: "tmp/interpreter_anthropic_evidence/probe-20261010T030043Z-98220bd5/runs/probe-20261010T030043Z-98220bd5/phase1/claude-haiku-5-5/opus_2026_10_09/tool_input.json",
      source_sha256: "a8133bc0143284539378e1c31b3b04de84bfe00ee489fd8ce5d664e06418b45c",
      judgment_path: "tmp/interpreter_anthropic_evidence/probe-20261010T030043Z-98220bd5/runs/probe-20261010T030043Z-98220bd5/phase1/claude-haiku-5-5/opus_2026_10_09/judgment.json",
      judgment_sha256: "5e73f5a9fac0aa56ebe56b7ecc311a4b523ff4be5ad4fc70b5b6197ae4a25299",
      fixture: "haiku55_opus.json",
      kind: :tool,
      historical: "pass",
      historical_reason: "allowed_move"
    }
  ].freeze

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
    @document = nil
    @session = nil
  end

  test "original captures stay byte for byte and keep their historical judgment" do
    CASES.each do |spec|
      payload = tool_input(spec)
      assert_equal spec[:key] == "haiku55_original" ? "new_work" : (spec[:key] == "bedrock_meta" ? "meta" : "report"), payload["move"]
      assert_historical_file(spec)
      assert_source_intact(spec)
    end

    capture_path = Rails.root.join(CASES.first[:source])
    if capture_path.file?
      capture = JSON.parse(capture_path.read)
      raw = capture["events"].find { |event| event["kind"] == "interpreter_raw" }
      route = capture["events"].find { |event| event["kind"] == "route_decision" }
      assert_equal "meta", raw.dig("tool_input", "move")
      assert_equal false, route["retrieval"]
    end
    assert_equal "not_accepted", CASES.first[:historical]
  end

  test "an empty pinned episode keeps the question, the manual, and no invented model" do
    CASES.each do |spec|
      summary, judgment = replay(spec)

      assert_equal spec[:historical], judgment["historical"], spec[:key]
      assert_equal "pass", judgment["acceptance"], "#{spec[:key]} #{judgment["reasons"]} #{summary.slice("route", "condition", "query", "goal_after", "model_after", "manufacturer_after", "identifiers_after")}"
      assert_equal [ @document.id ], summary["focus_after"], spec[:key]
      assert_not_includes summary["identifiers_after"], SYMPTOM, spec[:key]
      assert_nil summary["model_after"], spec[:key]
      assert_nil summary["fault_code_after"], spec[:key]
    end
  end

  test "a brake job and the door question are an ambiguous relation, not a continuity verdict" do
    CASES.each do |spec|
      summary, judgment = replay(spec, scenario: :brakes)

      assert_equal spec[:historical], judgment["historical"], spec[:key]
      assert_equal "pass", judgment["acceptance"], "#{spec[:key]} #{judgment["reasons"]}"
      assert_equal [ @document.id ], summary["focus_before"], spec[:key]
      assert_equal summary["focus_before"], summary["focus_after"], spec[:key]
      assert_includes summary["query"], "seguridad de esa puerta", spec[:key]
      assert_equal "ep_active_job", summary["episode_before_id"], spec[:key]
      assert_equal BRAKE_GOAL, summary["goal_before"], spec[:key]
      # The captured new_work was produced with an empty context. Replaying it
      # here records the current policy. It does not score this relation.
      if captured_move(spec) == "new_work"
        assert_not_equal summary["episode_before_id"], summary["episode_after_id"], spec[:key]
        assert_equal({}, @session.current_procedure)
      else
        assert_equal summary["episode_before_id"], summary["episode_after_id"], spec[:key]
        assert_equal BRAKE_GOAL, summary["goal_after"], spec[:key]
        assert_equal({ "name" => "ajuste" }, @session.current_procedure)
      end
    end
  end

  test "replaying the captured payloads on the same door job records a new_work restart" do
    CASES.each do |spec|
      summary, judgment = replay(spec, scenario: :door)

      assert_equal spec[:historical], judgment["historical"], spec[:key]
      assert_equal [ @document.id ], summary["focus_before"], spec[:key]
      assert_equal summary["focus_before"], summary["focus_after"], spec[:key]
      assert_includes summary["query"], "seguridad de esa puerta", spec[:key]
      assert_equal DOOR_EPISODE, summary["episode_before_id"], spec[:key]
      assert_equal DOOR_GOAL, summary["goal_before"], spec[:key]
      assert_includes summary["observations_before"], DOOR_OBSERVATION, spec[:key]
      assert_equal "ready", summary["route"], spec[:key]
      assert_equal true, summary["retrieval"], spec[:key]

      # Captured with empty context. This replay is not a live follow-up.
      if captured_move(spec) == "new_work"
        assert_equal "fail", judgment["acceptance"], spec[:key]
        assert_includes judgment["reasons"], "silent_restart", spec[:key]
        assert_not_equal DOOR_EPISODE, summary["episode_after_id"], spec[:key]
        assert_not_equal DOOR_GOAL, summary["goal_after"], spec[:key]
        assert_not_includes summary["observations_after"], DOOR_OBSERVATION, spec[:key]
        assert_equal({}, @session.current_procedure)
      else
        assert_equal "pass", judgment["acceptance"], "#{spec[:key]} #{judgment["reasons"]}"
        assert_equal DOOR_EPISODE, summary["episode_after_id"], spec[:key]
        assert_equal DOOR_GOAL, summary["goal_after"], spec[:key]
        assert_includes summary["observations_after"], DOOR_OBSERVATION, spec[:key]
        assert_equal DOOR_PROCEDURE, @session.current_procedure
      end
    end
  end

  private

  def replay(spec, scenario: nil)
    @session = web_session
    @document ||= elemont_document
    assert @session.pin_kb_document!(@document), spec[:key]
    seed_scenario(@session, scenario) if scenario
    events = []
    result = nil
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
        isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
          isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
            events = Rag::ValidationCapture.capture do
              result = @session.record_user_turn!(
                TURN,
                user_id: @user.id,
                correlation_id: "journey:#{spec[:key]}:#{SecureRandom.hex(3)}",
                interpreter_client: PayloadStub.new(tool_input(spec))
              )
            end
          end
        end
      end
    end
    assert_equal TURN, @session.reload.conversation_history.last["content"]
    assert_nil result.understanding.clarification if spec[:unconfirmed]
    summary = Rag::JourneyReview.summarize(events)
    judgment = Rag::JourneyReview.judge(summary, checks_for(spec, scenario: scenario))
    [ summary, judgment ]
  end

  def checks_for(spec, scenario:)
    checks = {
      historical: spec[:historical],
      retrieval: true,
      query_includes: [ "Elemont MH", "seguridad de esa puerta" ],
      forbid_model: true,
      forbid_fault_code: true,
      forbidden_identifiers: [ SYMPTOM ],
      focus_stable: true,
      audited_turn: TURN
    }
    if spec[:unconfirmed]
      checks[:no_unconfirmed_writes] = true
      checks[:manufacturer_blank] = scenario.nil?
    else
      checks[:manufacturer] = "Elemont"
    end
    checks[:manufacturer] = "Elemont" if scenario && spec[:unconfirmed]
    if scenario == :door
      checks[:episode_stable] = true
      checks[:prior_goal] = DOOR_GOAL
    end
    checks
  end

  def captured_move(spec)
    tool_input(spec).fetch("move")
  end

  def tool_input(spec)
    snapshot = JSON.parse(fixture_path(spec).read)
    original = original_tool_input(spec)
    assert_equal snapshot, original, spec[:source] if original
    snapshot
  end

  def original_tool_input(spec)
    path = Rails.root.join(spec[:source])
    return nil unless path.file?

    data = JSON.parse(path.read)
    if spec[:kind] == :capture
      data["events"].find { |event| event["kind"] == "interpreter_raw" }.fetch("tool_input")
    else
      data.fetch("tool_input")
    end
  end

  def assert_source_intact(spec)
    path = Rails.root.join(spec[:source])
    return unless path.file?

    assert_equal spec[:source_sha256], Digest::SHA256.file(path).hexdigest, spec[:source]
  end

  def assert_historical_file(spec)
    return if spec[:judgment_path].blank?

    path = Rails.root.join(spec[:judgment_path])
    return unless path.file?

    body = JSON.parse(path.read)
    assert_equal spec[:historical], body["judgment"], spec[:key]
    assert_equal spec[:historical_reason], body["reason"], spec[:key]
    assert_equal spec[:judgment_sha256], Digest::SHA256.file(path).hexdigest, spec[:judgment_path]
  end

  def fixture_path(spec)
    Rails.root.join("test/fixtures/files/field_companion/journey_20261010", spec[:fixture])
  end

  def elemont_document
    KbDocument.create!(
      s3_key: ELEMONT_KEY,
      document_uid: ELEMONT_UID,
      display_name: "Elemont Montacargas Hidraulico Modelo MH",
      aliases: [],
      account: @account
    )
  end

  def web_session
    ConversationSession.create!(
      identifier: "web:journey:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 30.days.from_now,
      user: @user,
      account: @account
    )
  end

  def seed_scenario(session, scenario)
    seeded = scenario == :door
    session.update!(
      active_episode: {
        "v" => 1,
        "episode_id" => seeded ? DOOR_EPISODE : "ep_active_job",
        "status" => "active",
        "opened_at" => Time.current.iso8601,
        "updated_at" => Time.current.iso8601,
        "goal" => {
          "text" => seeded ? DOOR_GOAL : BRAKE_GOAL,
          "correlation_id" => "seed",
          "truncated" => false
        },
        "facts" => {
          "manufacturer" => { "status" => "known", "value" => "Elemont", "source" => "user" }
        },
        "identifiers" => [
          { "value" => "Elemont MH", "source" => "user", "correlation_id" => "seed" }
        ],
        "observations" => [
          {
            "text" => seeded ? DOOR_OBSERVATION : "el freno queda abierto",
            "correlation_id" => "seed"
          }
        ],
        "conflicts" => []
      },
      current_procedure: seeded ? DOOR_PROCEDURE : { "name" => "ajuste" }
    )
  end

  class PayloadStub
    def initialize(payload)
      @payload = payload
    end

    def converse(_params)
      tool = Struct.new(:name, :input).new("turn_perception", @payload)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage).new(output, usage)
    end
  end
end
